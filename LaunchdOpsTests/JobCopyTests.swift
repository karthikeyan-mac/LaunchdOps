import Foundation
import Testing

@testable import LaunchdOps

struct DuplicateJobTests {
  private func project() -> Project {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/local/bin/backup"
    job.additionalKeys["LegacyTimers"] = .bool(true)
    var project = Project()
    project.jobs = [job]
    project.payload = [
      PayloadFile(name: "backup", destination: "/usr/local/bin", mode: 0o755, contents: Data("x".utf8))
    ]
    project.settings.name = "Backup"
    project.settings.packageIdentifier = "com.acme.pkg.backup"
    project.settings.publishedLabels = ["com.acme.backup"]
    project.settings.retiredLabels = ["com.acme.oldbackup"]
    return project
  }

  @Test func copyGetsNewIdentitiesAndKeepsEveryKey() {
    let original = project()
    let copy = original.duplicated(existingLabels: ["com.acme.backup"])
    let job = copy.jobs[0]
    #expect(job.label == "com.acme.backup.copy")
    #expect(job.id != original.jobs[0].id)
    #expect(job.program == "/usr/local/bin/backup")
    #expect(job.additionalKeys["LegacyTimers"] == .bool(true))
    #expect(copy.payload[0].id != original.payload[0].id)
    #expect(copy.payload[0].contents == original.payload[0].contents)
    #expect(copy.settings.name == "Backup Copy")
    // Nothing that identifies the job on a Mac or in an MDM is shared with the original.
    #expect(copy.settings.packageIdentifier.isEmpty)
    #expect(copy.resolved().settings.packageIdentifier == "com.acme.backup.copy")
    #expect(copy.settings.profileUUID != original.settings.profileUUID)
    #expect(copy.settings.profilePayloadUUID != original.settings.profilePayloadUUID)
    #expect(copy.settings.publishedLabels.isEmpty)
    #expect(copy.settings.retiredLabels.isEmpty)
  }

  @Test func labelsStayUnique() {
    #expect(Project.copyLabel(for: "com.acme.backup", avoiding: []) == "com.acme.backup.copy")
    let taken: Set = ["com.acme.backup.copy", "com.acme.backup.copy2"]
    #expect(Project.copyLabel(for: "com.acme.backup", avoiding: taken) == "com.acme.backup.copy3")
  }

  @Test func ddmTaskTypeFollowsTheNewLabel() {
    var ddm = project()
    ddm.settings.mode = .declarative
    ddm.settings.taskType = "com.acme.backup"
    #expect(ddm.duplicated(existingLabels: []).settings.taskType == "com.acme.backup.copy")
  }
}

struct ClipboardJobTests {
  private let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>com.acme.sync</string>
    <key>ProgramArguments</key><array><string>/usr/local/bin/sync</string></array>
    <key>MachServices</key><dict><key>com.acme.sync.xpc</key><true/></dict>
    </dict></plist>
    """

  @Test func readsAPlistAndKeepsUnknownKeys() throws {
    let project = try Project.fromClipboard(plist)
    let job = try #require(project.jobs.first)
    #expect(job.label == "com.acme.sync")
    #expect(job.context == .daemon)
    #expect(job.additionalKeys["MachServices"] != nil)
    #expect(project.settings.publishedLabels == ["com.acme.sync"])
  }

  @Test func sessionTypeMakesItAnAgent() throws {
    let agent = plist.replacingOccurrences(
      of: "<key>MachServices</key>",
      with: "<key>LimitLoadToSessionType</key><string>Aqua</string><key>MachServices</key>"
    )
    #expect(try Project.fromClipboard(agent).jobs.first?.context == .globalAgent)
  }

  @Test func rejectsWhatIsNotALaunchdPlist() {
    #expect(throws: Project.ClipboardError.empty) { try Project.fromClipboard(nil) }
    #expect(throws: Project.ClipboardError.empty) { try Project.fromClipboard("  \n") }
    #expect(throws: Project.ClipboardError.notLaunchdPlist) { try Project.fromClipboard("hello") }
    let noLabel = plist.replacingOccurrences(of: "<key>Label</key><string>com.acme.sync</string>", with: "")
    #expect(throws: Project.ClipboardError.notLaunchdPlist) { try Project.fromClipboard(noLabel) }
    let huge = String(repeating: "a", count: Project.maximumClipboardPlistSize + 1)
    #expect(throws: Project.ClipboardError.tooLarge) { try Project.fromClipboard(huge) }
  }
}

struct CollectDiagnosticsTests {
  @Test func collectRecordsDisabledStateAndLogTails() {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/local/bin/backup"
    job.standardOutPath = "/Library/Logs/Acme/backup.log"
    job.standardErrorPath = "/Library/Logs/Acme/backup.error.log"
    var project = Project()
    project.jobs = [job]
    let check = ScriptGenerator.check(for: project.resolved())
    #expect(check.contains(#"/bin/launchctl print-disabled "$domain_target""#))
    #expect(check.contains(#"/usr/bin/tail -n 200 "$file""#))
    #expect(
      check.contains(
        "collect_job 'com.acme.backup' '/Library/LaunchDaemons/com.acme.backup.plist' 'system' "
          + #"'/Library/Logs/Acme/backup.log' '/Library/Logs/Acme/backup.error.log' "$output""#))
  }
}

struct AddArgumentTests {
  @Test func firstAddWithProgramSetStartsWithTheProgramPath() {
    let program = "/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync"
    let added = LaunchJob.addingArgument(to: [], program: program)
    #expect(added.map(\.value) == [program, ""])
    // Once the process name is there, Add adds one row for the next option.
    #expect(LaunchJob.addingArgument(to: added, program: program).map(\.value) == [program, "", ""])
  }

  @Test func emptyArgumentRowsAreLeftOutOfThePlist() throws {
    var job = LaunchJob(context: .daemon, label: "com.acme.sync")
    job.program = "/usr/local/bin/sync"
    job.arguments = [TextItem(value: "/usr/local/bin/sync"), TextItem(value: ""), TextItem(value: "--silent")]
    #expect(job.argumentValues == ["/usr/local/bin/sync", "--silent"])
    #expect(job.plistDictionary["ProgramArguments"] == .array([.string("/usr/local/bin/sync"), .string("--silent")]))
    #expect(JobExplainer.summarize(job).row(.program, "Command Line")?.value == "/usr/local/bin/sync --silent")

    job.arguments = [TextItem(value: "")]
    #expect(job.plistDictionary["ProgramArguments"] == nil)
  }

  @Test func withoutProgramAddAddsOneRow() {
    #expect(LaunchJob.addingArgument(to: [], program: "").map(\.value) == [""])
    #expect(LaunchJob.addingArgument(to: [], program: "  ").map(\.value) == [""])
  }
}
