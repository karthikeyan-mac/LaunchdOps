import Foundation
import Testing

@testable import LaunchdOps

@MainActor
struct ProjectLibraryTests {
  private let directory = FileManager.default.temporaryDirectory
    .appending(path: "LibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func sampleProject() -> Project {
    var project = Project()
    project.settings.name = "Backup Tools"
    project.jobs = [LaunchJob(context: .daemon, label: "com.example.backup")]
    let script = Data("#!/bin/zsh\n".utf8)
    project.payload = [PayloadFile(name: "run.sh", destination: "/usr/local/libexec", mode: 0o755, contents: script)]
    return project
  }

  /// An undo manager that records each call as its own group, as one user event would.
  private func undoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
  }

  private func grouped(_ manager: UndoManager, _ change: () -> Void) {
    manager.beginUndoGrouping()
    change()
    manager.endUndoGrouping()
  }

  @Test func savedProjectsLoadAtNextLaunch() throws {
    let library = ProjectLibrary(directory: directory)
    let id = library.create(sampleProject(), undoManager: nil)
    library.saveNow()
    #expect(!library.hasUnsavedChanges)

    let reopened = ProjectLibrary(directory: directory)
    #expect(reopened.entries.map(\.id) == [id])
    #expect(reopened.project(id) == library.project(id))
  }

  @Test func editsSaveAutomaticallyAfterAPause() async throws {
    let library = ProjectLibrary(directory: directory, saveDelay: .milliseconds(20))
    let id = library.create(sampleProject(), undoManager: nil)
    var project = try #require(library.project(id))
    project.settings.version = "2.0"
    library.apply(project, to: id, undoManager: nil)
    #expect(library.hasUnsavedChanges)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!library.hasUnsavedChanges)
    #expect(ProjectLibrary(directory: directory).project(id)?.settings.version == "2.0")
  }

  @Test func undoAndRedoRestoreEdits() throws {
    let library = ProjectLibrary(directory: directory)
    let undo = undoManager()
    let id = library.create(sampleProject(), undoManager: nil)
    var project = try #require(library.project(id))
    project.jobs[0].label = "com.example.renamed"
    grouped(undo) { library.apply(project, to: id, undoManager: undo) }

    undo.undo()
    #expect(library.project(id)?.jobs[0].label == "com.example.backup")
    undo.redo()
    #expect(library.project(id)?.jobs[0].label == "com.example.renamed")
  }

  @Test func deletingIsUndoable() throws {
    let library = ProjectLibrary(directory: directory)
    let undo = undoManager()
    let id = library.create(sampleProject(), undoManager: nil)
    library.saveNow()
    grouped(undo) { library.delete(id, undoManager: undo) }
    #expect(library.entries.isEmpty)
    #expect(ProjectLibrary(directory: directory).entries.isEmpty)

    undo.undo()
    library.saveNow()
    #expect(library.project(id) == sampleProject().withIDs(of: library.project(id)))
    #expect(ProjectLibrary(directory: directory).entries.map(\.id) == [id])
  }

  @Test func unreadableProjectIsSkippedAndKept() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let damaged = directory.appending(path: "\(UUID().uuidString).launchdops", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)

    let library = ProjectLibrary(directory: directory)
    #expect(library.entries.isEmpty)
    #expect(library.unreadableFiles == [damaged.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: damaged.path(percentEncoded: false)))
  }

  @Test func exportedProjectImportsUnchanged() throws {
    let library = ProjectLibrary(directory: directory)
    let original = sampleProject()
    let exported = directory.appending(path: "Exported.launchdops", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try ExportDocument(content: .project(original)).fileWrapper()
      .write(to: exported, options: .atomic, originalContentsURL: nil)

    let ids = try library.importProject(from: exported, undoManager: nil)
    #expect(ids.count == 1)
    #expect(library.project(ids.first) == original)
  }

  @Test func displayNameIsTheProjectNameElseTheLabel() {
    var project = Project()
    #expect(ProjectLibrary.displayName(of: project) == "Untitled Job")
    project.jobs = [LaunchJob(context: .daemon, label: "com.example.backup")]
    #expect(ProjectLibrary.displayName(of: project) == "com.example.backup")
    project.settings.name = "Backup Tools"
    #expect(ProjectLibrary.displayName(of: project) == "Backup Tools")
    project.settings.name = "  "
    #expect(ProjectLibrary.displayName(of: project) == "com.example.backup")
  }

  @Test func unchangedProjectAddsNoUndoStepOrSave() throws {
    let library = ProjectLibrary(directory: directory)
    let undo = undoManager()
    let id = library.create(sampleProject(), undoManager: nil)
    library.saveNow()
    let same = try #require(library.project(id))
    // No group: registering an undo outside one would raise, so this also proves nothing was registered.
    library.apply(same, to: id, undoManager: undo)
    #expect(!undo.canUndo)
    #expect(!library.hasUnsavedChanges)

    var changed = same
    changed.payload[0].contents = Data("#!/bin/zsh\necho changed\n".utf8)
    grouped(undo) { library.apply(changed, to: id, undoManager: undo) }
    #expect(undo.canUndo)
    #expect(library.hasUnsavedChanges)
  }

  @Test func renamingIsUndoable() throws {
    let library = ProjectLibrary(directory: directory)
    let undo = undoManager()
    let id = library.create(sampleProject(), undoManager: nil)
    var renamed = try #require(library.project(id))
    renamed.settings.name = "Nightly Backup"
    grouped(undo) { library.apply(renamed, to: id, undoManager: undo) }
    #expect(library.project(id).map(ProjectLibrary.displayName(of:)) == "Nightly Backup")
    undo.undo()
    #expect(library.project(id).map(ProjectLibrary.displayName(of:)) == "Backup Tools")
  }

  @Test func multiJobProjectsBecomeOneEntryPerJob() throws {
    var project = sampleProject()
    project.jobs.append(LaunchJob(context: .globalAgent, label: "com.example.notify"))
    let exported = directory.appending(path: "Two.launchdops", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try ProjectPackage.fileWrapper(for: project).write(to: exported, options: .atomic, originalContentsURL: nil)

    let library = ProjectLibrary(directory: directory.appending(path: "Library", directoryHint: .isDirectory))
    let ids = try library.importProject(from: exported, undoManager: nil)
    #expect(ids.count == 2)
    let labels = ids.compactMap { library.project($0)?.jobs.map(\.label) }
    #expect(labels == [["com.example.backup"], ["com.example.notify"]])
  }

  @Test func librarySplitsOldMultiJobFilesWhenLoading() throws {
    var project = sampleProject()
    project.jobs.append(LaunchJob(context: .globalAgent, label: "com.example.notify"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "\(UUID().uuidString).launchdops", directoryHint: .isDirectory)
    try ProjectPackage.fileWrapper(for: project).write(to: file, options: .atomic, originalContentsURL: nil)

    let library = ProjectLibrary(directory: directory)
    #expect(library.entries.map { $0.project.jobs.count } == [1, 1])
    library.saveNow()
    #expect(ProjectLibrary(directory: directory).entries.count == 2)
  }
}

extension Project {
  /// This project with the job, payload and profile identifiers of `other`, for comparing content only.
  fileprivate func withIDs(of other: Project?) -> Project? {
    guard let other, other.jobs.count == jobs.count, other.payload.count == payload.count else { return nil }
    var copy = self
    for index in copy.jobs.indices {
      copy.jobs[index].id = other.jobs[index].id
    }
    for index in copy.payload.indices {
      copy.payload[index].id = other.payload[index].id
    }
    copy.settings.profileUUID = other.settings.profileUUID
    copy.settings.profilePayloadUUID = other.settings.profilePayloadUUID
    return copy
  }
}

extension ExportDocument {
  /// The package the file exporter would write.
  fileprivate func fileWrapper() throws -> FileWrapper {
    switch content {
    case .project(let project): try ProjectPackage.fileWrapper(for: project)
    case .folder(let tree): tree.fileWrapper()
    case .file(let data): FileWrapper(regularFileWithContents: data)
    }
  }
}
