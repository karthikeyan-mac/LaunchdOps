import SwiftUI
import UniformTypeIdentifiers

struct ExportDocument: FileDocument {
  enum Content: Sendable {
    case folder(FileTree)
    case file(Data)
    /// A library project saved as a `.launchdops` package, for Project ▸ Export Project….
    case project(Project)
  }

  static var readableContentTypes: [UTType] { [.folder, .propertyList, .launchdOpsProject] }

  var content: Content

  init(content: Content) {
    self.content = content
  }

  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.featureUnsupported)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    switch content {
    case .folder(let tree):
      tree.fileWrapper()
    case .file(let data):
      FileWrapper(regularFileWithContents: data)
    case .project(let project):
      try ProjectPackage.fileWrapper(for: project)
    }
  }
}
