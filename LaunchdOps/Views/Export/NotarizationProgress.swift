import SwiftUI

/// What the toolbar shows while a package is being notarized: which package, which step and how long it has run.
struct NotarizationActivity: Equatable {
  let packageName: String
  let startedAt: Date
  var phase: NotaryClient.Phase

  enum Step: Int, CaseIterable {
    case upload
    case appleCheck
    case staple

    var title: String {
      switch self {
      case .upload: String(localized: "Upload to Apple")
      case .appleCheck: String(localized: "Apple checks the package")
      case .staple: String(localized: "Staple the ticket")
      }
    }
  }

  var currentStep: Step {
    switch phase {
    case .uploading: .upload
    case .waiting: .appleCheck
    case .stapling: .staple
    }
  }

  var shortStatus: String {
    switch phase {
    case .uploading: String(localized: "Uploading to Apple…")
    case .waiting: String(localized: "Waiting for Apple…")
    case .stapling: String(localized: "Stapling…")
    }
  }
}

/// Toolbar item shown on every tab while notarizing. Click it for the steps, elapsed time and Cancel.
struct NotarizationProgressButton: View {
  let activity: NotarizationActivity
  let onCancel: () -> Void

  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Notarizing")
      }
    }
    // Filled with the accent color so it stands out from the toolbar; orange and green already mean warning and OK.
    .buttonStyle(.borderedProminent)
    .help("Notarizing \(activity.packageName): \(activity.shortStatus) Click for details or to cancel.")
    .accessibilityLabel("Notarizing \(activity.packageName)")
    .accessibilityValue(activity.shortStatus)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      NotarizationProgressPopover(activity: activity) {
        isPresented = false
        onCancel()
      }
    }
  }
}

private struct NotarizationProgressPopover: View {
  let activity: NotarizationActivity
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Notarizing")
          .font(.headline)
        Text(activity.packageName)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(NotarizationActivity.Step.allCases, id: \.self) { step in
          StepRow(step: step, current: activity.currentStep)
        }
      }
      TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
        let elapsed = Duration.seconds(context.date.timeIntervalSince(activity.startedAt))
        Text("Elapsed: \(elapsed.formatted(.time(pattern: .minuteSecond)))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Text("Apple usually finishes within a few minutes. You can keep working; you’ll see the result when it’s done.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel Notarization", role: .cancel) { onCancel() }
      }
    }
    .padding(16)
    .frame(width: 300)
  }
}

private struct StepRow: View {
  let step: NotarizationActivity.Step
  let current: NotarizationActivity.Step

  var body: some View {
    HStack(spacing: 8) {
      Group {
        if step.rawValue < current.rawValue {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else if step == current {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "circle")
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: 16)
      Text(step.title)
        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(step.title))
    .accessibilityValue(Text(accessibilityState))
  }

  private var accessibilityState: String {
    if step.rawValue < current.rawValue { return String(localized: "Done") }
    return step == current ? String(localized: "In progress") : String(localized: "Not started")
  }
}
