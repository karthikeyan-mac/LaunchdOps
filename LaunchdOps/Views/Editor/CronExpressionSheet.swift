import SwiftUI

struct CronExpressionSheet: View {
  let onAdd: ([CalendarInterval]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var expression = ""
  @FocusState private var isFocused: Bool

  private enum Feedback {
    case hint
    case intervals([CalendarInterval])
    case error(String)
  }

  private var feedback: Feedback {
    guard !expression.trimmingCharacters(in: .whitespaces).isEmpty else { return .hint }
    do {
      switch try CronConverter.schedule(from: expression) {
      case .calendar(let intervals):
        return .intervals(intervals)
      case .atLoad:
        return .error(
          String(localized: "@reboot has no calendar equivalent. Turn on Run at Load in When to Run instead.")
        )
      }
    } catch {
      return .error(error.localizedDescription)
    }
  }

  private var intervals: [CalendarInterval]? {
    if case .intervals(let intervals) = feedback { return intervals }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add from Cron Expression")
          .font(.headline)
        Text("Enter the five time fields of a crontab line, or a special string such as @daily.")
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        TextField("Cron Expression", text: $expression, prompt: Text("0 9 * * 1-5"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .monospaced()
          .focused($isFocused)
          .accessibilityLabel("Cron expression")
          .onSubmit { add() }
        feedbackText
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") { add() }
          .keyboardShortcut(.defaultAction)
          .disabled(intervals == nil)
      }
    }
    .padding(24)
    .frame(width: 480)
    .onAppear { isFocused = true }
  }

  @ViewBuilder
  private var feedbackText: some View {
    switch feedback {
    case .hint:
      Text("Minute, hour, day of month, month and day of week, separated by spaces.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .intervals(let intervals):
      Text(addSummary(intervals))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    case .error(let message):
      Label(message, systemImage: "xmark.octagon.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func addSummary(_ intervals: [CalendarInterval]) -> String {
    let summary = CronConverter.Schedule.calendar(intervals).summary
    return intervals.count == 1
      ? String(localized: "Adds 1 schedule. \(summary)") : String(localized: "Adds \(summary)")
  }

  private func add() {
    guard let intervals else { return }
    onAdd(intervals)
    dismiss()
  }
}
