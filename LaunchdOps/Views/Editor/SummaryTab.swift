import SwiftUI

/// The selected job's plist, section by section: only the keys it contains, each row showing its plist key so the
/// summary also teaches the plist. Read-only; each section links to the tab that edits it.
struct SummaryTab: View {
  let job: LaunchJob
  let summary: JobSummary
  let issues: [ValidationIssue]
  let onSelectTab: (EditorTab) -> Void

  var body: some View {
    Form {
      Section {
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: job.context.systemImage)
            .font(.largeTitle)
            .foregroundStyle(.tint)
            .frame(width: 44)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text(job.displayName)
              .font(.title2.weight(.semibold))
              .monospaced()
              .textSelection(.enabled)
            Text("\(job.context.title) · \(job.installPath)")
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            Text(summary.styledHeadline)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
      }
      JobIssuesSection(issues: issues)
      ForEach(summary.sections) { section in
        Section {
          ForEach(section.rows) { row in
            SummaryRow(row: row)
          }
        } header: {
          HStack {
            Label(section.topic.title, systemImage: section.topic.systemImage)
            Spacer()
            Button("Edit in \(Self.tab(for: section.topic).title)") { onSelectTab(Self.tab(for: section.topic)) }
              .buttonStyle(.link)
              .font(.callout)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  static func tab(for topic: JobSummary.Topic) -> EditorTab {
    switch topic {
    case .general, .program: .general
    case .schedule, .restart, .logging, .environment, .other: .options
    }
  }
}

/// A label with its plist key underneath, and the value (with an optional note) on the right.
private struct SummaryRow: View {
  let row: JobSummary.Row

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        Text(row.value)
          .font(row.isCode ? .body.monospaced() : .body)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if let note = row.note {
          Text(note)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.label)
        if let key = row.key {
          Text(key)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .accessibilityLabel("plist key \(key)")
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
