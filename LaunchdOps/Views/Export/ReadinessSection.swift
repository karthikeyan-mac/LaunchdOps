import SwiftUI

/// Export tab ▸ Readiness: what the export will produce and what to check before deploying.
struct ReadinessSection: View {
  let readiness: ExportReadiness

  var body: some View {
    Section {
      ForEach(readiness.items) { item in
        LabeledContent {
          Text(item.detail)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        } label: {
          Label {
            Text(item.title)
          } icon: {
            ReadinessIcon(state: item.state)
          }
        }
        .accessibilityElement(children: .combine)
      }
    } header: {
      Text("Readiness")
    } footer: {
      Text(readiness.headline)
    }
  }
}

private struct ReadinessIcon: View {
  let state: ExportReadiness.State

  var body: some View {
    switch state {
    case .ready:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Ready")
    case .attention:
      SeverityIcon(severity: .warning)
    case .blocked:
      SeverityIcon(severity: .error)
    }
  }
}
