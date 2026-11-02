import OSLog
import SwiftUI

struct OutputPreview: View {
  let project: Project

  @State private var lines: [OutlineLine] = []
  @State private var failure: String?

  private let logger = Log.export

  var body: some View {
    Group {
      if let failure {
        Label {
          Text("The file list could not be built. \(failure)")
        } icon: {
          SeverityIcon(severity: .error)
        }
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(lines) { line in
            Label(line.name, systemImage: line.isFolder ? "folder" : "doc")
              .foregroundStyle(line.isFolder ? Color.secondary : Color.primary)
              .padding(.leading, CGFloat(line.depth) * 14)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .font(.callout.monospaced())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files that will be exported")
      }
    }
    .task(id: PreviewKey(project: project)) {
      await refresh()
    }
  }

  private func refresh() async {
    let snapshot = project
    do {
      let paths = try await Task.detached(priority: .utility) {
        try ProjectExporter.export(snapshot, buildsPackage: false).files.map(\.path)
      }.value
      guard !Task.isCancelled else { return }
      lines = OutputOutline.lines(for: paths, root: ProjectExporter.defaultFolderName(for: snapshot))
      failure = nil
    } catch {
      // A newer preview replaced this one; its result wins.
      guard !Task.isCancelled else { return }
      logger.error("Output preview failed: \(error.localizedDescription, privacy: .public)")
      failure = error.localizedDescription
    }
  }
}

private struct PreviewKey: Hashable {
  let settings: ProjectSettings
  let jobs: [LaunchJob]
  let payload: [PayloadKey]

  // Payload contents are left out so large files are not hashed on every edit.
  struct PayloadKey: Hashable {
    let id: PayloadFile.ID
    let name: String
    let destination: String
  }

  init(project: Project) {
    settings = project.settings
    jobs = project.jobs
    payload = project.payload.map { PayloadKey(id: $0.id, name: $0.name, destination: $0.destination) }
  }
}
