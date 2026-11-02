import Foundation
import Testing

@testable import LaunchdOps

struct PlistRoundTripTests {
  @Test func preservesUnknownKeys() throws {
    let source: [String: PlistValue] = [
      "Label": .string("com.example.test"),
      "ProgramArguments": .array([.string("/usr/local/libexec/run.sh"), .string("--quiet")]),
      "MachServices": .dictionary(["com.example.test": .bool(true)]),
      "LegacyTimers": .bool(true),
    ]
    let job = LaunchJob(dictionary: source, context: .daemon)
    #expect(job.additionalKeys.keys.sorted() == ["LegacyTimers", "MachServices"])
    #expect(job.plistDictionary == source)
  }

  @Test func convertsIntegerUmaskToOctalAndBack() {
    let job = LaunchJob(dictionary: ["Label": .string("a.b"), "Umask": .integer(18)], context: .daemon)
    #expect(job.umask == "022")
    #expect(job.plistDictionary["Umask"] == .integer(18))
  }

  @Test func singleCalendarIntervalStaysADictionary() {
    let interval: PlistValue = .dictionary(["Hour": .integer(13), "Minute": .integer(45)])
    let job = LaunchJob(dictionary: ["Label": .string("a.b"), "StartCalendarInterval": interval], context: .daemon)
    #expect(job.calendarIntervals.count == 1)
    #expect(job.plistDictionary["StartCalendarInterval"] == interval)
  }

  @Test func calendarArrayWithOneEntryReadsHourAndMinute() {
    let schedule: PlistValue = .array([.dictionary(["Hour": .integer(20), "Minute": .integer(8)])])
    let job = LaunchJob(
      dictionary: ["Label": .string("a.b"), "StartCalendarInterval": schedule],
      context: .globalAgent
    )
    #expect(job.calendarIntervals.count == 1)
    #expect(job.calendarIntervals.first?.hour == 20)
    #expect(job.calendarIntervals.first?.minute == 8)
    #expect(job.calendarIntervals.first?.summary == "Runs every day at 20:08.")
  }

  @Test func keepAliveConditionsRoundTrip() {
    let keepAlive: PlistValue = .dictionary([
      "SuccessfulExit": .bool(false),
      "PathState": .dictionary(["/tmp/flag": .bool(true)]),
      "OtherJobEnabled": .dictionary(["com.example.other": .bool(true)]),
    ])
    let job = LaunchJob(dictionary: ["Label": .string("a.b"), "KeepAlive": keepAlive], context: .daemon)
    #expect(job.keepAlive.mode == .conditional)
    #expect(job.keepAlive.otherKeys.keys.sorted() == ["OtherJobEnabled"])
    #expect(job.plistDictionary["KeepAlive"] == keepAlive)
  }

  @Test func renderedPlistParsesBack() throws {
    var job = LaunchJob(context: .daemon, label: "com.example.render")
    job.arguments = [TextItem(value: "/bin/echo"), TextItem(value: "hello & <world>")]
    let data = try job.renderedPlist()
    let parsed = try PropertyListCoding.dictionary(from: data)
    #expect(parsed == job.plistDictionary)
  }
}

struct ValidatorTests {
  private func project(with job: LaunchJob) -> Project {
    var project = Project()
    project.jobs = [job]
    return project
  }

  private func rules(_ job: LaunchJob) -> Set<String> {
    Set(Validator.validate(project(with: job)).map(\.rule))
  }

  @Test func flagsZeroExitTimeout() {
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/bin/tool"
    job.runAtLoad = true
    job.exitTimeOut = 0
    #expect(rules(job).contains("exit-timeout.zero"))
  }

  @Test func flagsSecretsInEnvironment() {
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/bin/tool"
    job.environment = [EnvironmentVariable(name: "API_TOKEN", value: "abc")]
    let issue = Validator.validate(project(with: job)).first { $0.rule == "secret.environment" }
    #expect(issue?.severity == .error)
  }

  @Test func flagsUserWritableProgramForDaemon() {
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/Users/Shared/run.sh"
    #expect(rules(job).contains("program.user-writable"))
  }

  @Test func flagsShellSyntaxWithoutShell() {
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.arguments = [TextItem(value: "/bin/echo"), TextItem(value: "$HOME")]
    #expect(rules(job).contains("arguments.shell"))

    job.arguments = [TextItem(value: "/bin/zsh"), TextItem(value: "-c"), TextItem(value: "echo $HOME")]
    #expect(!rules(job).contains("arguments.shell"))
  }

  @Test func rejectsInvalidLabels() {
    #expect(Validator.isValidLabel("com.example.job-1_a"))
    #expect(!Validator.isValidLabel("com.example.job; rm -rf /"))
    #expect(!Validator.isValidLabel("../evil"))
  }

  @Test func ddmWarnsWhenProgramOrScriptIsOutsideTheTaskFolder() {
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/bin/tool"
    job.runAtLoad = true
    var ddmProject = project(with: job)
    ddmProject.settings.mode = .declarative
    ddmProject.settings.taskType = "com.example.job"
    let outside = Validator.validate(ddmProject).filter { $0.rule == "ddm.program-location" }
    #expect(outside.map(\.severity) == [.warning])

    // A macOS program running a script: the script's path is what matters.
    ddmProject.jobs[0].program = ""
    ddmProject.jobs[0].arguments = [TextItem(value: "/bin/zsh"), TextItem(value: "/Library/Management/super/super")]
    let script = Validator.validate(ddmProject).filter { $0.rule == "ddm.program-location" }
    #expect(script.map(\.detail) == ["/Library/Management/super/super"])

    let inside = "\(Project.servicesRoot)/com.example.job/super"
    ddmProject.jobs[0].arguments = [TextItem(value: "/bin/zsh"), TextItem(value: inside)]
    #expect(!Validator.validate(ddmProject).contains { $0.rule == "ddm.program-location" })
  }
}

struct GeneratorTests {
  @Test func shellQuotingEscapesSingleQuotes() {
    #expect(Shell.quoted("it's") == #"'it'\''s'"#)
  }

  @Test func zipHasValidStructure() {
    var writer = ZipWriter()
    writer.addDirectory("task")
    writer.addFile("task/run.sh", contents: Data("echo hi\n".utf8), mode: 0o755)
    let archive = writer.archive()
    #expect(archive.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
    #expect(archive.suffix(22).prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
    #expect(writer.archive() == archive)
  }

  @Test func crcMatchesKnownValue() {
    #expect(CRC32.checksum(Data("hello world".utf8)) == 0x0D4A_1185)
  }

  @Test func exportContainsExpectedFiles() throws {
    var project = Project()
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.arguments = [TextItem(value: "/usr/local/libexec/run.sh")]
    job.runAtLoad = true
    project.jobs = [job]
    project.payload = [PayloadFile(name: "run.sh", destination: "/usr/local/libexec", mode: 0o755, contents: Data())]
    project.settings.packageOutput = .buildScript

    let paths = Set(try ProjectExporter.export(project).files.map(\.path))
    #expect(paths.contains("package/root/Library/LaunchDaemons/com.example.job.plist"))
    #expect(paths.contains("package/root/usr/local/libexec/run.sh"))
    #expect(paths.contains("package/scripts/postinstall"))
    #expect(paths.contains("uninstall.sh"))
    #expect(paths.contains("check.sh"))
  }

  @Test func exportIsDeterministic() throws {
    var project = Project()
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/bin/tool"
    job.environment = [EnvironmentVariable(name: "B", value: "2"), EnvironmentVariable(name: "A", value: "1")]
    project.jobs = [job]
    let first = try ProjectExporter.export(project).files
    let second = try ProjectExporter.export(project).files
    #expect(first == second)
  }

  @Test func documentPackageRoundTrips() throws {
    var project = Project()
    var job = LaunchJob(context: .globalAgent, label: "com.example.agent")
    job.program = "/usr/local/bin/tool"
    job.additionalKeys["LegacyTimers"] = .bool(true)
    project.jobs = [job]
    project.settings.name = "Round Trip"

    let wrapper = try ProjectPackage.fileWrapper(for: project)
    let loaded = try ProjectPackage.read(wrapper)
    #expect(loaded.settings == project.settings)
    #expect(loaded.jobs.first?.plistDictionary == job.plistDictionary)
    #expect(loaded.jobs.first?.context == .globalAgent)
    #expect(loaded.jobs.first?.id == job.id)
  }
}

struct ExportOptionTests {
  private func sampleProject() -> Project {
    var project = Project()
    var job = LaunchJob(context: .daemon, label: "com.example.job")
    job.program = "/usr/local/bin/tool"
    job.runAtLoad = true
    project.jobs = [job]
    return project
  }

  @Test func excludedItemsAreLeftOut() throws {
    var project = sampleProject()
    project.settings.includePackage = false
    project.settings.includeScripts = false
    project.settings.includeGuide = false
    project.settings.includeLoginItemsProfile = false

    let paths = Set(try ProjectExporter.export(project).files.map(\.path))
    #expect(paths == ["com.example.job.plist"])
  }

  @Test func exportIsOneFlatFolder() throws {
    var project = sampleProject()
    project.settings.packageOutput = .installerPackage
    let paths = Set(try ProjectExporter.export(project, buildsPackage: false).files.map(\.path))
    #expect(
      paths == [
        "com.example.job-1.0-unsigned.pkg", "com.example.job-ManagedLoginItems.mobileconfig",
        "com.example.job.plist", "check.sh", "uninstall.sh", "README.md",
      ])
  }

  @Test func signingIdentityIsQuotedInBuildScript() {
    var project = sampleProject()
    project.settings.signingIdentity = "Developer ID Installer: O'Brien (ABC123)"
    let script = PackageGenerator.buildScript(for: project)
    #expect(script.contains(#"default_identity='Developer ID Installer: O'\''Brien (ABC123)'"#))
  }

  @Test func olderSettingsDecodeWithDefaults() throws {
    let json = Data(#"{"name":"Old","mode":"package"}"#.utf8)
    let settings = try JSONDecoder().decode(ProjectSettings.self, from: json)
    #expect(settings.name == "Old")
    #expect(settings.includePackage)
    #expect(settings.includeGuide)
    #expect(settings.signingIdentity.isEmpty)
    #expect(settings.packageOutput == .buildScript)
    #expect(ProjectSettings().packageOutput == .installerPackage)
  }

  @Test func blankNameAndIdentifierFollowTheJobLabel() {
    var project = Project()
    var agent = LaunchJob(context: .globalAgent, label: "com.example.agent")
    agent.program = "/bin/true"
    var daemon = LaunchJob(context: .daemon, label: "com.microsoft.SyncReporter")
    daemon.program = "/bin/true"
    project.jobs = [agent, daemon]
    #expect(project.resolvedSettings.name == "com.microsoft.SyncReporter")
    #expect(project.resolvedSettings.packageIdentifier == "com.microsoft.SyncReporter")
    #expect(project.resolvedSettings.safeName == "com.microsoft.SyncReporter")
    #expect(ProjectExporter.defaultFolderName(for: project) == "com.microsoft.SyncReporter-1.0")

    project.settings.name = "Sync Tools"
    project.settings.packageIdentifier = "com.example.pkg.sync"
    #expect(project.resolvedSettings.name == "Sync Tools")
    #expect(project.resolvedSettings.packageIdentifier == "com.example.pkg.sync")
    #expect(!Validator.validate(project).contains { $0.rule == "package.identifier" })
  }

  @Test func oldDefaultNameAndIdentifierFollowTheLabel() throws {
    let json = Data(#"{"name":"Untitled","packageIdentifier":"com.example.pkg.untitled"}"#.utf8)
    let settings = try JSONDecoder().decode(ProjectSettings.self, from: json)
    #expect(settings.name.isEmpty)
    #expect(settings.packageIdentifier.isEmpty)
  }

  @Test func safeNameKeepsDotsButNotLeadingOnes() {
    var settings = ProjectSettings()
    settings.name = "../evil name"
    #expect(settings.safeName == "-evil-name")
    settings.name = ".."
    #expect(settings.safeName == "LaunchdOps")
  }

  @Test func uninstallQuotesTheProjectName() {
    var project = sampleProject()
    project.settings.name = #"Tools "$(rm -rf /)""#
    let script = ScriptGenerator.uninstall(for: project.resolved())
    #expect(script.contains(#"log_step 'removed Tools "$(rm -rf /)"'"#))
  }

  @Test func renamingAPublishedJobRetiresItsOldLabel() {
    var project = Project()
    project.jobs = [LaunchJob(context: .daemon, label: "com.example.backup")]
    project.markPublished(["com.example.backup"])

    project.jobs[0].label = "com.example.backup2"
    project.noteLabelChange(from: "com.example.backup", to: "com.example.backup2")
    #expect(project.settings.retiredLabels == ["com.example.backup"])

    // Renaming back takes it off the list again.
    project.jobs[0].label = "com.example.backup"
    project.noteLabelChange(from: "com.example.backup2", to: "com.example.backup")
    #expect(project.settings.retiredLabels.isEmpty)
  }

  @Test func renamingAnUnpublishedJobRetiresNothing() {
    var project = Project()
    project.jobs = [LaunchJob(context: .daemon, label: "com.example.daemon")]
    project.jobs[0].label = "com.example.backup"
    project.noteLabelChange(from: "com.example.daemon", to: "com.example.backup")
    #expect(project.settings.retiredLabels.isEmpty)
  }

  @Test func oldLabelStillUsedByAnotherJobIsNotRetired() {
    var project = Project()
    project.jobs = [
      LaunchJob(context: .daemon, label: "com.example.renamed"),
      LaunchJob(context: .globalAgent, label: "com.example.shared"),
    ]
    project.markPublished(["com.example.shared"])
    project.noteLabelChange(from: "com.example.shared", to: "com.example.renamed")
    #expect(project.settings.retiredLabels.isEmpty)
  }

  @Test func publishedLabelsDecodeWhenMissing() throws {
    let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(#"{"name":"Old"}"#.utf8))
    #expect(settings.publishedLabels.isEmpty)
  }

  @Test func outlineListsFoldersOnce() {
    let lines = OutputOutline.lines(for: ["b/two.sh", "a.md", "b/one.sh"], root: "Out")
    #expect(lines.map(\.name) == ["Out/", "a.md", "b/", "one.sh", "two.sh"])
    #expect(lines.map(\.depth) == [0, 1, 1, 2, 2])
  }
}
