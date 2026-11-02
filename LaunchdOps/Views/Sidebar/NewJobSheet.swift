import SwiftUI

struct NewJobSheet: View {
  let suggestedLabel: (JobContext) -> String
  /// Labels other jobs already use.
  let existingLabels: Set<String>
  let onCreate: (JobContext, String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var kind = JobContext.daemon
  @State private var label = ""
  @State private var labelSelection: TextSelection?
  @FocusState private var isLabelFocused: Bool

  private var isLabelValid: Bool {
    Validator.isValidLabel(label) && !label.hasSuffix(".") && !existingLabels.contains(label)
  }

  /// Why Create is disabled, shown under the field.
  private var labelProblem: String? {
    if label.isEmpty { return nil }
    if !Validator.isValidLabel(label) {
      return String(localized: "Use only letters, numbers, dots, hyphens and underscores.")
    }
    if label.hasSuffix(".") { return String(localized: "Add a name after the last dot, for example \(label)backup.") }
    if existingLabels.contains(label) { return String(localized: "Another job already uses this label.") }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New Job")
          .font(.headline)
        Text("What kind of launchd job do you want to create?")
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 8) {
        KindOption(
          context: .daemon,
          title: "Launch Daemon",
          detail: "Runs as root in the system domain, whether or not anyone is logged in. Cannot show UI.",
          selection: $kind
        )
        KindOption(
          context: .globalAgent,
          title: "Launch Agent",
          detail: "Runs in each user’s login session, as that user. Can show UI and notifications.",
          selection: $kind
        )
        KindOption(
          context: .userAgent,
          title: "User Launch Agent",
          detail: "Runs for one user only. Exported as a plist; not included in the package or DDM background tasks.",
          selection: $kind
        )
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Job type")

      VStack(alignment: .leading, spacing: 6) {
        Text("Label")
          .fontWeight(.medium)
        TextField("Label", text: $label, selection: $labelSelection, prompt: Text("com.example.backup"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .monospaced()
          .focused($isLabelFocused)
          .onSubmit { create() }
        if let labelProblem {
          Label(labelProblem, systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
        } else {
          Text("Reverse-DNS form. The label is also the plist file name.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(!isLabelValid)
      }
    }
    .padding(24)
    .frame(width: 480)
    .onAppear {
      label = suggestedLabel(kind)
      // Cursor after the suggestion, so typing adds to the prefix instead of replacing it.
      labelSelection = TextSelection(insertionPoint: label.endIndex)
      isLabelFocused = true
    }
    .onChange(of: kind) { oldKind, newKind in
      // Only replace the label while it still holds the untouched suggestion.
      if label == suggestedLabel(oldKind) {
        label = suggestedLabel(newKind)
      }
    }
  }

  private func create() {
    guard isLabelValid else { return }
    onCreate(kind, label)
    dismiss()
  }
}

private struct KindOption: View {
  let context: JobContext
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  @Binding var selection: JobContext

  private var isSelected: Bool { selection == context }

  var body: some View {
    Button {
      selection = context
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isSelected ? "circle.inset.filled" : "circle")
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .padding(.top, 2)
          .accessibilityHidden(true)
        Image(systemName: context.systemImage)
          .font(.title3)
          .foregroundStyle(.tint)
          .frame(width: 32, height: 32)
          .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .fontWeight(.semibold)
          Text(detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(context.installDirectory)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
      .contentShape(RoundedRectangle(cornerRadius: 10))
      .background {
        RoundedRectangle(cornerRadius: 10)
          .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
