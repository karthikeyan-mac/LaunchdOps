import Foundation

/// Each library job's highest issue severity, so every sidebar row can show its status. A job is validated again
/// only when it or the signing settings change; unchanged jobs reuse the last result.
@MainActor
final class SeverityCache {
  private struct Result {
    let project: Project
    let signing: SigningPreferences
    let severity: IssueSeverity?
  }

  private var results: [UUID: Result] = [:]

  /// `selected` passes the selected job's issues, which the window has already computed.
  func severities(
    for entries: [ProjectLibrary.Entry],
    signing: SigningPreferences,
    selected: (id: UUID, issues: [ValidationIssue])?
  ) -> [UUID: IssueSeverity] {
    var next: [UUID: Result] = [:]
    for entry in entries {
      let severity: IssueSeverity?
      if let selected, selected.id == entry.id {
        severity = selected.issues.highestSeverity
      } else if let cached = results[entry.id], cached.signing == signing,
        ProjectLibrary.isUnchanged(cached.project, entry.project)
      {
        severity = cached.severity
      } else {
        severity = Validator.validate(signing.applied(to: entry.project)).highestSeverity
      }
      next[entry.id] = Result(project: entry.project, signing: signing, severity: severity)
    }
    results = next
    return next.compactMapValues(\.severity)
  }
}
