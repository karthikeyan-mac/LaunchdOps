import SwiftUI

struct PayloadField: View {
  @Binding var project: Project
  @Binding var job: LaunchJob
  let onAddFiles: () -> Void

  @State private var editingID: PayloadFile.ID?

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      ForEach(project.payload) { file in
        Button {
          editingID = file.id
        } label: {
          Label {
            HStack(spacing: 6) {
              Text(file.name)
                .monospaced()
              Text(file.modeString)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: file.isExecutable ? "terminal" : "doc")
          }
        }
        .help(project.installPath(for: file))
        .accessibilityHint("Edits the payload file")
        .popover(isPresented: isEditing(file.id), arrowEdge: .trailing) {
          if let binding = binding(for: file.id) {
            PayloadEditor(
              file: binding,
              installPath: project.installPath(for: binding.wrappedValue),
              isPackageMode: project.settings.mode == .package,
              onUseAsProgram: { useAsProgram(file.id) },
              onRemove: { remove(file.id) }
            )
          }
        }
        .onDeleteCommand { remove(file.id) }
        .contextMenu {
          Button("Use as Program") { useAsProgram(file.id) }
          Button("Remove", role: .destructive) { remove(file.id) }
        }
      }
      Button("Add Files…") { onAddFiles() }
    }
  }

  private func isEditing(_ id: PayloadFile.ID) -> Binding<Bool> {
    Binding(
      get: { editingID == id },
      set: { if !$0 { editingID = nil } }
    )
  }

  private func binding(for id: PayloadFile.ID) -> Binding<PayloadFile>? {
    guard let current = project.payload.first(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { project.payload.first { $0.id == id } ?? current },
      set: { newValue in
        if let index = project.payload.firstIndex(where: { $0.id == id }) {
          project.payload[index] = newValue
        }
      }
    )
  }

  private func useAsProgram(_ id: PayloadFile.ID) {
    guard let index = project.payload.firstIndex(where: { $0.id == id }) else { return }
    let path = project.installPath(for: project.payload[index])
    if !job.program.isEmpty || job.arguments.isEmpty {
      job.program = path
    } else {
      job.arguments[0].value = path
    }
    if !project.payload[index].isExecutable {
      project.payload[index].mode = 0o755
    }
    editingID = nil
  }

  private func remove(_ id: PayloadFile.ID) {
    editingID = nil
    project.payload.removeAll { $0.id == id }
  }
}

private struct PayloadEditor: View {
  @Binding var file: PayloadFile
  let installPath: String
  let isPackageMode: Bool
  let onUseAsProgram: () -> Void
  let onRemove: () -> Void

  private static let modes: [(value: Int, title: LocalizedStringResource)] = [
    (0o755, "755 · Executable"),
    (0o700, "700 · Executable, root only"),
    (0o644, "644 · Readable"),
    (0o600, "600 · Root only")
  ]

  var body: some View {
    Form {
      TextField("File Name", text: $file.name)
        .monospaced()
      TextField(
        isPackageMode ? "Install Folder" : "Subfolder",
        text: $file.destination,
        prompt: Text(isPackageMode ? Project.defaultPayloadDestination : "Optional")
      )
      .monospaced()
      Picker("Mode", selection: $file.mode) {
        ForEach(Self.modes, id: \.value) { mode in
          Text(mode.title).tag(mode.value)
        }
        if !Self.modes.contains(where: { $0.value == file.mode }) {
          Text(file.modeString).tag(file.mode)
        }
      }
      LabeledContent("Installs To") {
        Text(installPath)
          .monospaced()
          .textSelection(.enabled)
      }
      LabeledContent("Size", value: file.contents.count.formatted(.byteCount(style: .file)))
      HStack {
        Button("Remove", role: .destructive) { onRemove() }
        Spacer()
        Button("Use as Program") { onUseAsProgram() }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
  }
}
