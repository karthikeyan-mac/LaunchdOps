import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static var launchdOpsProject: UTType {
    UTType(exportedAs: "com.karthikmac.launchdops.project", conformingTo: .package)
  }
}

/// Reads and writes the `.launchdops` package format, used for the project library and for Export and
/// Import Project.
enum ProjectPackage {
  enum PackageError: LocalizedError {
    case missingManifest
    case unsupportedVersion(Int)
    case missingFile(String)
    case invalidMode(String, Int)
    case duplicateID(UUID)

    var errorDescription: String? {
      switch self {
      case .invalidMode(let name, let mode):
        "The project gives \(name) the file mode \(mode), which isn’t a valid permission value (0 to 0o7777)."
      case .duplicateID(let id):
        "The project lists the item \(id.uuidString) more than once, so it may have been edited by hand."
      case .missingManifest:
        "The project is missing its project.json manifest."
      case .unsupportedVersion(let version):
        "This project was created by a newer version of LaunchdOps (format \(version)). Update LaunchdOps to open it."
      case .missingFile(let name):
        "The project is missing \(name)."
      }
    }
  }

  private struct Manifest: Codable {
    var formatVersion: Int
    var settings: ProjectSettings
    var jobs: [JobEntry]
    var payload: [PayloadEntry]

    struct JobEntry: Codable {
      var id: UUID
      var context: JobContext
      var file: String
    }

    struct PayloadEntry: Codable {
      var id: UUID
      var name: String
      var destination: String
      var mode: Int
      var file: String
    }
  }

  private static let formatVersion = 1
  private static let manifestName = "project.json"
  private static let jobsFolder = "Jobs"
  private static let payloadFolder = "Payload"

  static func read(_ wrapper: FileWrapper) throws -> Project {
    guard let manifestData = wrapper.fileWrappers?[manifestName]?.regularFileContents else {
      throw PackageError.missingManifest
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    guard manifest.formatVersion <= formatVersion else {
      throw PackageError.unsupportedVersion(manifest.formatVersion)
    }

    // Projects can come from anyone; reject what the app would never write before using any of it.
    let ids = manifest.jobs.map(\.id) + manifest.payload.map(\.id)
    var seen = Set<UUID>()
    if let duplicate = ids.first(where: { !seen.insert($0).inserted }) {
      throw PackageError.duplicateID(duplicate)
    }
    if let bad = manifest.payload.first(where: { !(0...0o7777).contains($0.mode) }) {
      throw PackageError.invalidMode(bad.name, bad.mode)
    }

    let jobFiles = wrapper.fileWrappers?[jobsFolder]?.fileWrappers ?? [:]
    let payloadFiles = wrapper.fileWrappers?[payloadFolder]?.fileWrappers ?? [:]

    var project = Project(settings: manifest.settings)
    for entry in manifest.jobs {
      guard let data = jobFiles[entry.file]?.regularFileContents else {
        throw PackageError.missingFile("\(jobsFolder)/\(entry.file)")
      }
      var job = LaunchJob(dictionary: try PropertyListCoding.dictionary(from: data), context: entry.context)
      job.id = entry.id
      project.jobs.append(job)
    }
    for entry in manifest.payload {
      guard let data = payloadFiles[entry.file]?.regularFileContents else {
        throw PackageError.missingFile("\(payloadFolder)/\(entry.file)")
      }
      project.payload.append(
        PayloadFile(id: entry.id, name: entry.name, destination: entry.destination, mode: entry.mode, contents: data)
      )
    }
    return project
  }

  static func fileWrapper(for project: Project) throws -> FileWrapper {
    var jobWrappers: [String: FileWrapper] = [:]
    var jobEntries: [Manifest.JobEntry] = []
    for job in project.jobs {
      let file = "\(job.id.uuidString).plist"
      jobWrappers[file] = FileWrapper(regularFileWithContents: try job.renderedPlist())
      jobEntries.append(Manifest.JobEntry(id: job.id, context: job.context, file: file))
    }

    var payloadWrappers: [String: FileWrapper] = [:]
    var payloadEntries: [Manifest.PayloadEntry] = []
    for file in project.payload {
      let name = file.id.uuidString
      payloadWrappers[name] = FileWrapper(regularFileWithContents: file.contents)
      payloadEntries.append(
        Manifest.PayloadEntry(id: file.id, name: file.name, destination: file.destination, mode: file.mode, file: name)
      )
    }

    let manifest = Manifest(
      formatVersion: formatVersion,
      settings: project.settings,
      jobs: jobEntries,
      payload: payloadEntries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    return FileWrapper(directoryWithFileWrappers: [
      manifestName: FileWrapper(regularFileWithContents: try encoder.encode(manifest)),
      jobsFolder: FileWrapper(directoryWithFileWrappers: jobWrappers),
      payloadFolder: FileWrapper(directoryWithFileWrappers: payloadWrappers),
    ])
  }
}
