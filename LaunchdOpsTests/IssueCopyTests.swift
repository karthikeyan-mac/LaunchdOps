import Foundation
import Testing

@testable import LaunchdOps

struct IssueCopyTests {
  @Test func copiedIssueNamesSeverityMessageAndSource() {
    let issue = ValidationIssue("label.missing", .error, "Label is required.", source: .launchdPlist)
    #expect(issue.copyText == "Error: Label is required. (launchd.plist(5))")
  }

  @Test func copyAllPutsEachIssueOnItsOwnLine() {
    let issues = [
      ValidationIssue("label.missing", .error, "Label is required.", source: .launchdPlist),
      ValidationIssue("package.unsigned", .warning, "The package will be unsigned.", source: .packaging),
    ]
    #expect(
      issues.copyText
        == "Error: Label is required. (launchd.plist(5))\nWarning: The package will be unsigned. (LaunchdOps packaging check)"
    )
  }

  @Test func consoleSearchNamesThisAppsSubsystem() {
    #expect(ConsoleLog.search.hasPrefix("subsystem:"))
    #expect(ConsoleLog.search.hasSuffix("LaunchdOps"))
  }
}
