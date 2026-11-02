import SwiftUI

struct ValidationStatusButton: View {
  let issues: [ValidationIssue]
  @Binding var isPresented: Bool
  let onSelectIssue: (ValidationIssue) -> Void

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label {
        title
      } icon: {
        Image(systemName: symbol)
          .foregroundStyle(color)
      }
      .labelStyle(.titleAndIcon)
    }
    .help("Show validation issues")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      let shown = issues.filter { $0.severity > .info }
      VStack(spacing: 0) {
        IssuesList(issues: shown) { issue in
          isPresented = false
          onSelectIssue(issue)
        }
        if !shown.isEmpty {
          Divider()
          HStack {
            Spacer()
            Button("Copy All Issues", systemImage: "doc.on.doc") { Pasteboard.copy(shown.copyText) }
          }
          .padding(10)
        }
      }
      .frame(width: 380)
      .frame(minHeight: 160, idealHeight: 360)
    }
  }

  private var title: Text {
    if issues.errorCount > 0 {
      Text("^[\(issues.errorCount) Error](inflect: true)")
    } else if issues.warningCount > 0 {
      Text("^[\(issues.warningCount) Warning](inflect: true)")
    } else {
      Text("No Errors")
    }
  }

  private var symbol: String {
    if issues.errorCount > 0 { return IssueSeverity.error.systemImage }
    if issues.warningCount > 0 { return IssueSeverity.warning.systemImage }
    return "checkmark.circle.fill"
  }

  private var color: Color {
    if issues.errorCount > 0 { return .red }
    if issues.warningCount > 0 { return .orange }
    return .green
  }
}

struct IssuesList: View {
  let issues: [ValidationIssue]
  let onSelectIssue: (ValidationIssue) -> Void

  var body: some View {
    if issues.isEmpty {
      ContentUnavailableView(
        "No Errors or Warnings",
        systemImage: "checkmark.seal",
        description: Text("Checked against launchd.plist(5) and Apple’s deployment rules.")
      )
    } else {
      List(issues) { issue in
        Button {
          onSelectIssue(issue)
        } label: {
          IssueRow(issue: issue)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

struct IssueRow: View {
  let issue: ValidationIssue

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      SeverityIcon(severity: issue.severity)
      VStack(alignment: .leading, spacing: 3) {
        Text(issue.message)
          .fixedSize(horizontal: false, vertical: true)
        Text("\(issue.severity.title): \(issue.severity.guidance) · \(issue.source.rawValue)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .contextMenu {
      Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(issue.copyText) }
    }
  }
}
