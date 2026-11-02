import SwiftUI

struct EnvironmentTextSheet: View {
  let onAdd: ([EnvironmentVariable.Assignment]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @FocusState private var isFocused: Bool

  private var parsed: EnvironmentVariable.ParsedText {
    EnvironmentVariable.parse(text)
  }

  private var canAdd: Bool {
    !parsed.assignments.isEmpty && parsed.invalidLines.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add Variables from Text")
          .font(.headline)
        Text("Paste one NAME=value per line. Blank lines and lines starting with # are skipped.")
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        TextEditor(text: $text)
          .monospaced()
          .frame(minHeight: 160)
          .focused($isFocused)
          .accessibilityLabel("Environment variables, one NAME=value per line")
        feedback
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") {
          onAdd(parsed.assignments)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canAdd)
      }
    }
    .padding(24)
    .frame(width: 480)
    .onAppear { isFocused = true }
  }

  @ViewBuilder
  private var feedback: some View {
    let parsed = parsed
    if !parsed.invalidLines.isEmpty {
      let lines = parsed.invalidLines.map(String.init).joined(separator: ", ")
      let message: LocalizedStringKey =
        parsed.invalidLines.count == 1
        ? "Line \(lines) is not NAME=value. Names use letters, numbers and underscores, not starting with a number."
        : "Lines \(lines) are not NAME=value. Names use letters, numbers and underscores, not starting with a number."
      Label(message, systemImage: "xmark.octagon.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    } else if parsed.assignments.isEmpty {
      Text("Plists are readable by every user on the Mac. Never paste passwords or tokens.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text(
        "Adds ^[\(parsed.assignments.count) variable](inflect: true). Existing variables with the same name are replaced."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
