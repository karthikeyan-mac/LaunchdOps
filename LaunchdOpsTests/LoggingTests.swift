import Foundation
import Testing

@testable import LaunchdOps

struct LoggingTests {
  /// A backup daemon that runs every hour and exits, unless `keepAlive` keeps it running.
  private func daemonProject(rotate: Bool = true, keepAlive: KeepAliveMode = .off) -> Project {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/local/libexec/backup"
    job.startInterval = 3600
    job.keepAlive.mode = keepAlive
    job.useLogFolder("/Library/Logs/Acme/")
    var project = Project()
    project.jobs = [job]
    project.settings.rotateLogs = rotate
    return project.resolved()
  }

  @Test func newDaemonsWriteToTheLogFolder() {
    var daemon = LaunchJob(context: .daemon, label: "com.acme.backup")
    daemon.useLogFolder(" /Library/Logs/Acme/ ")
    #expect(daemon.standardOutPath == "/Library/Logs/Acme/com.acme.backup.log")
    #expect(daemon.standardErrorPath == "/Library/Logs/Acme/com.acme.backup.error.log")

    var agent = LaunchJob(context: .globalAgent, label: "com.acme.notify")
    agent.useLogFolder("/Library/Logs/Acme")
    #expect(agent.standardOutPath.isEmpty)  // Agents run as the user and can't write to a root-owned folder.

    for unsafe in ["Logs/Acme", "/", "/Users/Shared/Logs", "/tmp/logs"] {
      var job = LaunchJob(context: .daemon, label: "com.acme.backup")
      job.useLogFolder(unsafe)
      #expect(job.standardOutPath.isEmpty, "\(unsafe) should be ignored")
    }
  }

  @Test func rotationRuleCoversTheDaemonLogs() throws {
    let project = daemonProject()
    let rule = try #require(LogRotation.configFile(for: project))
    #expect(rule.path == "/private/etc/newsyslog.d/com.acme.backup.conf")
    // N: no SIGHUP to syslogd (newsyslog.conf(5) sends one when a rule names no PID file). Z: gzip.
    #expect(rule.contents.contains("/Library/Logs/Acme/com.acme.backup.log\troot:wheel\t644\t5\t10240\t*\tNZ"))
    #expect(rule.contents.contains("/Library/Logs/Acme/com.acme.backup.error.log\troot:wheel\t644\t5\t10240\t*\tNZ"))
    #expect(LogRotation.logFolders(for: project) == ["/Library/Logs/Acme"])
  }

  @Test func noRuleWhenRotationIsOffOrNotApplicable() {
    #expect(LogRotation.configFile(for: daemonProject(rotate: false)) == nil)
    // A job that keeps running holds its log open; rotating it would lose output.
    #expect(LogRotation.configFile(for: daemonProject(keepAlive: .always)) == nil)
    var ddm = daemonProject()
    ddm.settings.mode = .declarative
    #expect(LogRotation.configFile(for: ddm) == nil)
    var spaced = daemonProject()
    spaced.jobs[0].standardOutPath = "/Library/Logs/Acme Corp/backup.log"
    spaced.jobs[0].standardErrorPath = ""
    #expect(LogRotation.configFile(for: spaced) == nil)
  }

  @Test func packageAndScriptsInstallAndRemoveTheRule() throws {
    let project = daemonProject()
    let rule = try #require(LogRotation.configFile(for: project))
    let input = try FlatPackageBuilder.input(for: project)
    #expect(input.files.contains { $0.path == rule.path && $0.permissions == 0o644 })

    let postinstall = ScriptGenerator.postinstall(for: project)
    #expect(postinstall.contains("/usr/sbin/chown root:wheel '\(rule.path)'"))
    #expect(postinstall.contains("make_log_folder '/Library/Logs/Acme'"))
    #expect(ScriptGenerator.uninstall(for: project).contains("/bin/rm -f '\(rule.path)'"))
    #expect(ScriptGenerator.check(for: project).contains("check_file '\(rule.path)' 644"))

    var buildScript = project
    buildScript.settings.packageOutput = .buildScript
    let files = try ProjectExporter.export(buildScript).files.map(\.path)
    #expect(files.contains("package/root\(rule.path)"))
  }

  @Test func ruleFromAnEarlierVersionIsRemovedWhenRotationIsOff() {
    // v1 rotated logs; v2 turns it off or keeps the job running. Installing v2 or uninstalling must remove the rule.
    let removal = "/bin/rm -f '/private/etc/newsyslog.d/com.acme.backup.conf'"
    for project in [daemonProject(rotate: false), daemonProject(keepAlive: .always), daemonProject()] {
      #expect(ScriptGenerator.preinstall(for: project).contains(removal))
      #expect(ScriptGenerator.uninstall(for: project).contains(removal))
    }
  }

  @Test func scriptsRecordEachStepInTheUnifiedLog() {
    let project = daemonProject()
    for script in [
      ScriptGenerator.preinstall(for: project), ScriptGenerator.postinstall(for: project),
      ScriptGenerator.uninstall(for: project),
    ] {
      #expect(script.contains(#"/usr/bin/logger -- "LaunchdOps: $*""#))
    }
    #expect(ScriptGenerator.postinstall(for: project).contains(#"log_step "loaded $label""#))
    #expect(ScriptGenerator.postinstall(for: project).contains("log_step 'installed com.acme.backup 1.0'"))
    #expect(ScriptGenerator.check(for: project).contains("install-steps.log"))
  }

  @Test func validatorGuidesLogRotation() {
    let rules = { (project: Project) in Validator.validate(project).map(\.rule) }
    #expect(rules(daemonProject(rotate: false)).contains("log.rotation"))
    #expect(!rules(daemonProject(rotate: true)).contains("log.rotation"))
    let longRunning = rules(daemonProject(rotate: false, keepAlive: .always))
    #expect(longRunning.contains("log.keepalive-file"))
    #expect(!longRunning.contains("log.rotation"))

    var spaced = daemonProject()
    spaced.jobs[0].standardOutPath = "/Library/Logs/Acme Corp/backup.log"
    #expect(rules(spaced).contains("log.rotation-path"))
  }

  @Test func oldProjectsLoadWithRotationOff() throws {
    let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data("{}".utf8))
    #expect(!settings.rotateLogs)
  }
}

struct GuideNotarizationTests {
  private func readme(signed: Bool, notarize: Bool) -> String {
    var signing = SigningPreferences()
    signing.signsPackage = signed
    signing.packageIdentity = "Developer ID Installer: Example (ABCDE12345)"
    signing.notarizeAfterExport = notarize
    var project = Project()
    project.jobs = [LaunchJob(context: .daemon, label: "com.acme.backup")]
    return GuideGenerator.readme(for: signing.applied(to: project).resolved(), profileName: nil)
  }

  @Test func automaticNotarizationNeedsNoManualSteps() {
    let text = readme(signed: true, notarize: true)
    #expect(!text.contains("notarytool submit"))
    #expect(text.contains("xcrun stapler validate"))
  }

  @Test func manualNotarizationListsTheSteps() {
    let text = readme(signed: true, notarize: false)
    #expect(text.contains("notarytool submit"))
    #expect(text.contains("xcrun stapler staple"))
  }

  @Test func unsignedPackageExplainsSigningFirst() {
    let text = readme(signed: false, notarize: false)
    #expect(!text.contains("notarytool submit"))
    #expect(text.contains("Apple notarizes only signed packages"))
  }
}

struct BackgroundTaskGuideTests {
  private func ddmProject(taskType: String) -> Project {
    var job = LaunchJob(context: .daemon, label: "com.github.runjamfproinventoryupdate")
    job.arguments = [
      TextItem(value: "\(Project.servicesRoot)/com.github.runjamfproinventoryupdate/runjamfproinventoryupdate.sh")
    ]
    var project = Project()
    project.jobs = [job]
    project.settings.mode = .declarative
    project.settings.taskType = taskType
    project.payload = [
      PayloadFile(
        name: "runjamfproinventoryupdate.sh", destination: "", mode: 0o755, contents: Data("#!/bin/zsh\n".utf8)
      )
    ]
    return project.resolved()
  }

  @Test func taskTypeShouldMatchTheDaemonLabel() {
    let matching = Validator.validate(ddmProject(taskType: "com.github.runjamfproinventoryupdate")).map(\.rule)
    #expect(!matching.contains("ddm.task-type-label"))
    let different = Validator.validate(ddmProject(taskType: "com.github.inventory")).map(\.rule)
    #expect(different.contains("ddm.task-type-label"))
  }

  @Test func readmeListsEveryBackgroundTaskField() throws {
    let project = ddmProject(taskType: "com.github.runjamfproinventoryupdate")
    let assets = try DeclarativeGenerator.generate(for: project).assets
    let readme = GuideGenerator.readme(for: project, profileName: nil)
    #expect(readme.contains("| Task type (`TaskType`) | `com.github.runjamfproinventoryupdate`"))
    let zip = try #require(assets.first { $0.contentType == "application/zip" })
    let zipRow =
      "| Executable asset (`ExecutableAssetReference`) | URL of `\(zip.fileName)`, SHA-256 `\(zip.hash)`, "
      + "content type `application/zip` |"
    #expect(readme.contains(zipRow))
    let plistRow = "| Launchd asset 1 (`LaunchdConfigurations`) | URL of `com.github.runjamfproinventoryupdate.plist`"
    #expect(readme.contains(plistRow))
    #expect(readme.contains("curl -sI"))
    #expect(readme.contains("Background Tasks: com.github.runjamfproinventoryupdate"))
  }
}

struct VendorNeutralOutputTests {
  private func readme() throws -> String {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/local/libexec/backup"
    var project = Project()
    project.jobs = [job]
    return GuideGenerator.readme(for: project.resolved(), profileName: "Backup-ManagedLoginItems.mobileconfig")
  }

  @Test func deployStepsWorkWithAnyMDMAndNameSeveralTools() throws {
    let text = try readme()
    #expect(text.contains("Use any MDM or software distribution tool"))
    for tool in ["Jamf Pro", "Microsoft Intune", "Workspace ONE", "Addigy", "Kandji", "Mosyle", "Munki"] {
      #expect(text.contains(tool), "README should mention \(tool)")
    }
  }

  @Test func profileStepStaysInTheDeployList() throws {
    // CommonMark: a list item numbered 4 can't interrupt a paragraph, so it must follow step 3 directly.
    let steps = "use `uninstall.sh`.\n4. Deliver `Backup-ManagedLoginItems.mobileconfig`"
    #expect(try readme().contains(steps))
  }

  @Test func checkScriptWorksWithOrWithoutResultTags() {
    var project = Project()
    project.jobs = [LaunchJob(context: .daemon, label: "com.acme.backup")]
    let check = ScriptGenerator.check(for: project.resolved())
    #expect(check.contains("RESULT_TAGS=false"))
    #expect(check.contains("--result) RESULT_TAGS=true ;;"))
    #expect(check.contains(#"echo "<result>$summary</result>""#))
    #expect(check.contains(#"echo "$summary""#))
  }

  @Test func checkScriptReportsEveryPackagedJobIncludingUserAgents() {
    // The review found verify.sh printed only the version for a project with just a User Launch Agent.
    var agent = LaunchJob(context: .userAgent, label: "com.acme.sync")
    agent.program = "/Applications/Sync.app/Contents/MacOS/Sync"
    var daemon = LaunchJob(context: .daemon, label: "com.acme.backup")
    daemon.program = "/usr/local/bin/backup"
    var project = Project()
    project.jobs = [agent, daemon]
    let check = ScriptGenerator.check(for: project.resolved())
    #expect(check.contains(#"results+=("$(job_status 'com.acme.backup' 'system' '/usr/local/bin/backup')")"#))
    #expect(
      check.contains(#"results+=("$(job_status 'com.acme.sync' 'gui' '/Applications/Sync.app/Contents/MacOS/Sync')")"#))
    #expect(check.contains("$label=program-missing"))
  }
}
