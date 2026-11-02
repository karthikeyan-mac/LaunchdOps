import SwiftUI

/// Sets the name shown in the sidebar, which is also Export ▸ Project Name.
struct RenameSheet: View {
  let label: String
  let onRename: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String

  init(name: String, label: String, onRename: @escaping (String) -> Void) {
    self.label = label
    self.onRename = onRename
    _name = State(initialValue: name)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename")
        .font(.headline)
      TextField("Name", text: $name, prompt: Text(label.isEmpty ? "Backup Tools" : label))
        .onSubmit { rename() }
      Text(
        """
        Also the Project Name on the Export tab, which names the export folder and package. Leave empty to use the \
        job label.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { rename() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 380)
  }

  private func rename() {
    onRename(name.trimmingCharacters(in: .whitespacesAndNewlines))
    dismiss()
  }
}
