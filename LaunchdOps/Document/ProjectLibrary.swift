import Foundation
import OSLog
import Observation

/// Every job the user has, each a one-job project saved automatically as a `.launchdops` package in the app's
/// container (`Application Support/Projects/<id>.launchdops`). There are no Save dialogs: edits are written about
/// a second after they stop, and immediately when the app quits or moves to the background.
@MainActor
@Observable
final class ProjectLibrary {
  struct Entry: Identifiable {
    let id: UUID
    var project: Project
  }

  private(set) var entries: [Entry] = []
  /// Files that could not be read at launch; they stay on disk untouched.
  private(set) var unreadableFiles: [String] = []

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var unsaved: Set<UUID> = []
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private let saveDelay: Duration
  @ObservationIgnored private let logger = Log.library

  static let fileExtension = "launchdops"

  /// The library in the app's container.
  static func standard() -> ProjectLibrary {
    let support = URL.applicationSupportDirectory
    return ProjectLibrary(directory: support.appending(path: "Projects", directoryHint: .isDirectory))
  }

  init(directory: URL, saveDelay: Duration = .seconds(1)) {
    self.directory = directory
    self.saveDelay = saveDelay
    load()
  }

  // MARK: - Reading

  func project(_ id: UUID?) -> Project? {
    guard let id else { return nil }
    return entries.first { $0.id == id }?.project
  }

  /// Name shown in the sidebar and window title: Export ▸ Project Name, else the job's label.
  static func displayName(of project: Project) -> String {
    let name = project.settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    return project.primaryLabel ?? String(localized: "Untitled Job")
  }

  /// A label not used by any job in the library, for the New Job sheet.
  func nextLabel(for context: JobContext, prefix: String = "") -> String {
    var all = Project()
    all.jobs = entries.flatMap(\.project.jobs)
    return all.nextLabel(for: context, prefix: prefix)
  }

  private func load() {
    let files: [URL]
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == Self.fileExtension }
    } catch {
      logger.error("Library folder unreadable: \(error.localizedDescription, privacy: .public)")
      return
    }
    var loaded: [Entry] = []
    var split: [UUID] = []
    for file in files {
      guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
      do {
        let wrapper = try FileWrapper(url: file, options: .immediate)
        let project = try ProjectPackage.read(wrapper)
        guard !project.jobs.isEmpty else {
          logger.info("Project \(file.lastPathComponent, privacy: .public) has no jobs; not shown")
          continue
        }
        // A project with several jobs (from an earlier version) becomes one entry per job; the file is rewritten
        // with the first job and the others get new files.
        let parts = project.splitByJob()
        loaded.append(Entry(id: id, project: parts[0]))
        for part in parts.dropFirst() {
          let newID = UUID()
          loaded.append(Entry(id: newID, project: part))
          split.append(newID)
        }
        if parts.count > 1 {
          split.append(id)
        }
      } catch {
        let name = file.lastPathComponent
        logger.error("Project \(name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
        unreadableFiles.append(file.lastPathComponent)
      }
    }
    entries = loaded.sorted {
      Self.displayName(of: $0.project).localizedStandardCompare(Self.displayName(of: $1.project)) == .orderedAscending
    }
    for id in split {
      markChanged(id)
    }
    logger.info("Loaded \(loaded.count) jobs, \(self.unreadableFiles.count) unreadable")
  }

  // MARK: - Changing

  /// Replaces a project and records the previous value with `undoManager`, so Undo and Redo restore it.
  func apply(_ project: Project, to id: UUID, undoManager: UndoManager?) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    let previous = entries[index].project
    guard !Self.isUnchanged(previous, project) else { return }
    entries[index].project = project
    markChanged(id)
    undoManager?.registerUndo(withTarget: self) { library in
      library.apply(previous, to: id, undoManager: undoManager)
    }
  }

  /// Cheap fields first, so payload bytes (up to 50 MB each) are compared only when everything else matches.
  static func isUnchanged(_ old: Project, _ new: Project) -> Bool {
    guard old.settings == new.settings, old.jobs == new.jobs, old.payload.count == new.payload.count else {
      return false
    }
    return zip(old.payload, new.payload).allSatisfy { a, b in
      a.id == b.id && a.name == b.name && a.destination == b.destination && a.mode == b.mode
        && a.contents.count == b.contents.count && a.contents == b.contents
    }
  }

  @discardableResult
  func create(_ project: Project = Project(), undoManager: UndoManager?) -> UUID {
    let id = UUID()
    insert(Entry(id: id, project: project), at: entries.endIndex, undoManager: undoManager)
    return id
  }

  func delete(_ id: UUID, undoManager: UndoManager?) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    let entry = entries.remove(at: index)
    unsaved.remove(id)
    logger.info("Deleted \(entry.project.primaryLabel ?? id.uuidString, privacy: .public)")
    do {
      try FileManager.default.removeItem(at: url(for: id))
    } catch CocoaError.fileNoSuchFile {
      // Never saved yet; nothing on disk.
    } catch {
      logger.error("Deleting project failed: \(error.localizedDescription, privacy: .public)")
    }
    undoManager?.registerUndo(withTarget: self) { library in
      library.insert(entry, at: index, undoManager: undoManager)
    }
  }

  private func insert(_ entry: Entry, at index: Int, undoManager: UndoManager?) {
    entries.insert(entry, at: min(index, entries.endIndex))
    markChanged(entry.id)
    undoManager?.registerUndo(withTarget: self) { library in
      library.delete(entry.id, undoManager: undoManager)
    }
  }

  /// Adds a copy of a `.launchdops` package chosen by the user or opened from Finder, one entry per job.
  func importProject(from url: URL, undoManager: UndoManager?) throws -> [UUID] {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    let project = try ProjectPackage.read(try FileWrapper(url: url, options: .immediate))
    guard !project.jobs.isEmpty else { throw ImportError.noJobs }
    return project.splitByJob().map { create($0, undoManager: undoManager) }
  }

  enum ImportError: LocalizedError {
    case noJobs

    var errorDescription: String? {
      "The project has no jobs to import."
    }
  }

  // MARK: - Saving

  private func url(for id: UUID) -> URL {
    directory.appending(path: "\(id.uuidString).\(Self.fileExtension)", directoryHint: .isDirectory)
  }

  private func markChanged(_ id: UUID) {
    unsaved.insert(id)
    saveTask?.cancel()
    let delay = saveDelay
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return  // A newer edit rescheduled the save.
      }
      self?.saveNow()
    }
  }

  /// Writes every changed project. Each write goes to a temporary file first, so a crash never leaves a
  /// half-written project.
  func saveNow() {
    saveTask?.cancel()
    saveTask = nil
    for id in unsaved {
      guard let project = project(id) else { continue }
      let label = project.primaryLabel ?? id.uuidString
      do {
        let wrapper = try ProjectPackage.fileWrapper(for: project)
        try wrapper.write(to: url(for: id), options: .atomic, originalContentsURL: nil)
      } catch {
        logger.error("Saving \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        continue
      }
      logger.debug("Saved \(label, privacy: .public)")
      unsaved.remove(id)
    }
  }

  var hasUnsavedChanges: Bool { !unsaved.isEmpty }
}
