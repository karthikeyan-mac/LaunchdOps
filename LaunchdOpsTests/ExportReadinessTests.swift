import Foundation
import Testing

@testable import LaunchdOps

struct ExportReadinessTests {
  private func project(_ configure: (inout ProjectSettings) -> Void = { _ in }) -> Project {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/bin/true"
    var project = Project()
    project.jobs = [job]
    project.settings.packageOutput = .installerPackage
    configure(&project.settings)
    return project
  }

  @Test func signedNotarizedPackageWithNoIssuesIsReady() {
    let readiness = ExportReadiness(
      project: project {
        $0.signingIdentity = "Developer ID Installer: Acme (ABCDE12345)"
        $0.notarizeAfterExport = true
      },
      issues: []
    )
    #expect(readiness.state == .ready)
    #expect(readiness.items.map(\.title) == ["Validation", "Package", "Notarization", "Profile"])
  }

  @Test func unsignedPackageNeedsAttention() {
    let readiness = ExportReadiness(project: project(), issues: [])
    #expect(readiness.state == .attention)
    #expect(readiness.items.first { $0.title == "Package" }?.state == .attention)
    #expect(!readiness.items.contains { $0.title == "Notarization" })
  }

  @Test func errorsAndBlockingIssuesBlock() {
    let error = ValidationIssue("package.version", .error, "Enter a version.", source: .packaging)
    #expect(ExportReadiness(project: project(), issues: [error]).state == .blocked)
    #expect(ExportReadiness(project: project(), issues: [error]).items[0].detail == "1 error to fix")

    let unsafe = ValidationIssue("label.characters", .error, "Unsafe label.", source: .security, blocking: true)
    #expect(ExportReadiness(project: project(), issues: [unsafe]).items[0].detail == "1 unsafe value stops the export")
  }

  @Test func ddmExportsListTheHostingStep() {
    let readiness = ExportReadiness(project: project { $0.mode = .declarative }, issues: [])
    #expect(readiness.items.contains { $0.title == "Background Task" && $0.state == .attention })
    #expect(!readiness.items.contains { $0.title == "Package" })
  }
}

struct IssueNavigationTests {
  private func area(_ rule: String) -> EditorArea? {
    ValidationIssue(rule, .error, "", source: .launchdPlist).editorArea
  }

  @Test func issuesOpenTheTabThatFixesThem() {
    #expect(area("label.characters") == .general)
    #expect(area("program.location-unverified") == .general)
    #expect(area("secret.argument") == .general)
    #expect(area("calendar.range") == .options)
    #expect(area("keep-alive.empty") == .options)
    #expect(area("secret.environment") == .options)
    #expect(area("payload.writable") == .general)  // Payload files are edited on General.
    #expect(area("ddm.task-type") == .export)
    #expect(area("path.absolute") == nil)  // Several fields on different tabs.
  }
}
