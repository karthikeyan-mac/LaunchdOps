import Foundation

enum IssueSeverity: Int, Comparable, CaseIterable, Sendable {
  case info
  case warning
  case error

  static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var title: String {
    switch self {
    case .info: "Note"
    case .warning: "Warning"
    case .error: "Error"
    }
  }

  /// What the admin should do about an issue of this severity.
  var guidance: String {
    switch self {
    case .info: "recommendation"
    case .warning: "review before deploying"
    case .error: "must fix"
    }
  }

  var systemImage: String {
    switch self {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }
}

/// The editor tab that fixes an issue. Mirrors the editing tabs of `EditorTab` without depending on views.
enum EditorArea: Sendable {
  case general
  case options
  case export
}

enum IssueSource: String, Sendable {
  case launchdPlist = "launchd.plist(5)"
  case launchctl = "launchctl(1)"
  case daemonsGuide = "Apple: Creating Launch Daemons and Agents"
  case backgroundTasks = "Apple DDM: com.apple.configuration.services.background-tasks"
  case serviceManagement = "Apple MDM: com.apple.servicemanagement"
  case notarization = "Apple: Notarizing macOS software before distribution"
  case security = "LaunchdOps security check"
  case packaging = "LaunchdOps packaging check"
}

struct ValidationIssue: Identifiable, Hashable, Sendable {
  let rule: String
  let severity: IssueSeverity
  let message: String
  let source: IssueSource
  let jobID: LaunchJob.ID?
  let detail: String
  /// A value that would be unsafe in file paths or root install scripts. Export Anyway can't override these;
  /// `ProjectExporter.checkSafety` enforces the same conditions as the final gate.
  let isBlocking: Bool

  var id: String {
    "\(rule)|\(jobID?.uuidString ?? "project")|\(detail)"
  }

  /// The part of the editor where this issue is fixed, from the rule's group; nil when it could be several.
  var editorArea: EditorArea? {
    let group = rule.split(separator: ".").first.map(String.init) ?? rule
    return switch group {
    case "label", "program", "arguments", "context", "payload": .general
    case "calendar", "interval", "keep-alive", "exit-timeout", "nice", "throttle", "trigger", "umask",
      "watch-paths", "log", "key":
      .options
    case "package", "ddm", "retired", "project": .export
    case "secret": rule == "secret.argument" ? .general : .options
    default: nil
    }
  }

  /// "Warning: message (source)", for copying into a ticket or chat.
  var copyText: String {
    "\(severity.title): \(message) (\(source.rawValue))"
  }

  init(
    _ rule: String,
    _ severity: IssueSeverity,
    _ message: String,
    source: IssueSource,
    job: LaunchJob.ID? = nil,
    detail: String = "",
    blocking: Bool = false
  ) {
    self.rule = rule
    self.severity = severity
    self.message = message
    self.source = source
    self.jobID = job
    self.detail = detail
    self.isBlocking = blocking
  }
}

extension Array where Element == ValidationIssue {
  var errorCount: Int { filter { $0.severity == .error }.count }
  var warningCount: Int { filter { $0.severity == .warning }.count }
  var blocking: [ValidationIssue] { filter(\.isBlocking) }

  func issues(for jobID: LaunchJob.ID) -> [ValidationIssue] {
    filter { $0.jobID == jobID }
  }

  var highestSeverity: IssueSeverity? {
    map(\.severity).max()
  }
}

extension [ValidationIssue] {
  /// Every issue on its own line, for Copy All Issues.
  var copyText: String {
    map(\.copyText).joined(separator: "\n")
  }
}
