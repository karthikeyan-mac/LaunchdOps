import Foundation
import Testing

@testable import LaunchdOps

struct JobExplainerTests {
  private var daemon: LaunchJob {
    var job = LaunchJob(context: .daemon, label: "com.acme.backup")
    job.program = "/usr/local/libexec/backup.sh"
    job.arguments = [TextItem(value: "backup.sh"), TextItem(value: "--full")]
    return job
  }

  @Test func onlyKeysInThePlistAppear() {
    let summary = JobExplainer.summarize(daemon)
    #expect(summary.sections.map(\.topic) == [.general, .program])
    #expect(summary.row(.program, "Runs As") == nil)  // UserName isn't set.
    #expect(summary.section(.logging) == nil)
    #expect(summary.section(.restart) == nil)
  }

  @Test func headlineSaysWhatRunsWhenAndIfRestarted() {
    var job = daemon
    job.runAtLoad = true
    job.calendarIntervals = [CalendarInterval(minute: 0, hour: 9)]
    #expect(
      JobExplainer.summarize(job).headline
        == "Runs `backup.sh` as root at startup and every day at 09:00. Not restarted if it stops."
    )
    let empty = JobExplainer.summarize(LaunchJob(context: .globalAgent, label: "com.acme.x"))
    #expect(empty.headline.contains("no program"))
  }

  @Test func styledHeadlineShowsTheProgramNameAsTypedInCodeStyle() {
    var job = daemon
    job.program = "/usr/local/bin/back`up_*now*.sh"
    let styled = JobExplainer.summarize(job).styledHeadline
    #expect(String(styled.characters).hasPrefix("Runs back`up_*now*.sh as root"))
    let code = styled.runs.filter { $0.inlinePresentationIntent == .code }.map { String(styled[$0.range].characters) }
    #expect(code == ["back`up_*now*.sh"])
  }

  @Test func programSectionShowsTheCommandLineAsTypedInTerminal() {
    let summary = JobExplainer.summarize(daemon)
    let command = summary.row(.program, "Command Line")
    #expect(command?.value == "/usr/local/libexec/backup.sh --full")
    #expect(command?.note?.contains("not through a shell") == true)
    // The command line replaces the per-argument rows, which repeated the General tab.
    #expect(summary.row(.program, "Program") == nil)
    #expect(summary.row(.program, "Argument 0") == nil)

    var argumentsOnly = daemon
    argumentsOnly.program = ""
    argumentsOnly.arguments = [
      TextItem(value: "/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync"), TextItem(value: "--silent"),
      TextItem(value: "it's"),
    ]
    #expect(
      JobExplainer.summarize(argumentsOnly).row(.program, "Command Line")?.value
        == #"'/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync' --silent 'it'\''s'"#
    )
  }

  @Test func programNamedDifferentlyFromItsPathIsNoted() {
    var job = daemon
    job.program = "/usr/local/libexec/backup.sh"
    job.arguments = [TextItem(value: "acme-backup"), TextItem(value: "--full")]
    let command = JobExplainer.summarize(job).row(.program, "Command Line")
    #expect(command?.value == "/usr/local/libexec/backup.sh --full")
    #expect(command?.note?.contains("The process is named acme-backup.") == true)
  }

  @Test func optionInTheProcessNameSlotIsFlagged() {
    // The AxM Jamf Sync plist: Program plus ProgramArguments ["--silent"] never passes --silent.
    var job = daemon
    job.program = "/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync"
    job.arguments = [TextItem(value: "--silent")]
    let command = JobExplainer.summarize(job).row(.program, "Command Line")
    #expect(command?.value == "'/Applications/AxM Jamf Sync.app/Contents/MacOS/AxM Jamf Sync'")
    #expect(command?.note?.contains("--silent isn’t passed to the program") == true)

    var project = Project()
    project.jobs = [job]
    #expect(Validator.validate(project).contains { $0.rule == "program.argv0-option" && $0.severity == .warning })
    job.arguments = [TextItem(value: job.program), TextItem(value: "--silent")]
    project.jobs = [job]
    #expect(!Validator.validate(project).contains { $0.rule == "program.argv0-option" })
  }

  @Test func shellCommandsShowTheScript() {
    var job = daemon
    job.program = ""
    job.arguments = [TextItem(value: "/bin/zsh"), TextItem(value: "-c"), TextItem(value: "echo $HOME | tee /tmp/x")]
    let summary = JobExplainer.summarize(job)
    #expect(summary.row(.program, "Command Line")?.value == "/bin/zsh -c 'echo $HOME | tee /tmp/x'")
    #expect(summary.row(.program, "Shell Script")?.value == "echo $HOME | tee /tmp/x")
    var direct = daemon
    direct.program = ""
    direct.arguments = [TextItem(value: "/usr/bin/true")]
    #expect(JobExplainer.summarize(direct).row(.program, "Shell Script") == nil)
  }

  @Test func scheduleShowsSetTriggersWithNotes() {
    var job = daemon
    job.startInterval = 300
    job.calendarIntervals = [CalendarInterval(minute: 0, hour: 9)]
    let summary = JobExplainer.summarize(job)
    #expect(summary.row(.schedule, "Repeats")?.value == "Every 5 minutes")
    #expect(summary.row(.schedule, "Repeats")?.note?.contains("Skipped while the Mac sleeps") == true)
    #expect(summary.row(.schedule, "Calendar")?.key == "StartCalendarInterval")
    #expect(summary.row(.schedule, "Run at Load") == nil)
  }

  @Test func keepAliveRowsNameTheirSubkeys() {
    var job = daemon
    job.keepAlive = KeepAlive(mode: .conditional, crashed: true)
    job.keepAlive.pathStates = [PathStateCondition(path: "/var/run/acme.flag", keepAliveWhenExists: true)]
    job.throttleInterval = 60
    let summary = JobExplainer.summarize(job)
    #expect(summary.row(.restart, "After Crash")?.key == "KeepAlive ▸ Crashed")
    #expect(summary.row(.restart, "While Exists")?.value == "/var/run/acme.flag")
    #expect(summary.row(.restart, "Minimum Gap")?.value == "1 minute")
  }

  @Test func loggingAndEnvironmentShowOnlyWhatIsSet() {
    var job = daemon
    job.standardOutPath = "/Library/Logs/Acme/backup.log"
    job.environment = [EnvironmentVariable(name: "API_HOST", value: "super-secret-value")]
    let summary = JobExplainer.summarize(job)
    #expect(summary.row(.logging, "Output")?.value == "/Library/Logs/Acme/backup.log")
    #expect(summary.row(.logging, "Errors") == nil)
    #expect(summary.row(.environment, "API_HOST")?.value == "Value hidden")
    let everything = summary.sections.flatMap(\.rows).map { "\($0.value) \($0.note ?? "")" }.joined() + summary.headline
    #expect(!everything.contains("super-secret-value"))
  }

  @Test func keysLaunchdOpsDoesNotEditAreListed() {
    var job = daemon
    job.additionalKeys = ["MachServices": .dictionary(["com.acme.backup.xpc": .bool(true)])]
    #expect(JobExplainer.summarize(job).row(.other, "MachServices")?.value == "Dictionary: 1 keys")
  }

  @Test func settingsAgentsIgnoreAreFlagged() {
    var agent = LaunchJob(context: .userAgent, label: "com.acme.agent")
    agent.program = "/usr/local/bin/agent"
    agent.userName = "root"
    agent.groupName = "wheel"
    agent.initGroups = true
    let summary = JobExplainer.summarize(agent)
    #expect(summary.row(.program, "Runs As")?.note?.contains("Ignored for agents") == true)
    #expect(summary.row(.program, "Group")?.note?.contains("Ignored for agents") == true)
    #expect(summary.row(.program, "Initialize Groups")?.note != nil)

    var job = daemon
    job.userName = "_acme"
    job.initGroups = false
    job.sessionTypes = ["Aqua"]
    let daemonSummary = JobExplainer.summarize(job)
    #expect(daemonSummary.row(.program, "Runs As")?.note == nil)
    #expect(daemonSummary.row(.program, "Initialize Groups")?.note == nil)
    #expect(daemonSummary.row(.program, "Sessions")?.note?.contains("no effect on daemons") == true)
    #expect(summary.row(.program, "Sessions") == nil)
  }

  @Test func disabledNoteSaysLaunchctlOverridesIt() {
    var job = daemon
    job.disabled = true
    let note = JobExplainer.summarize(job).row(.general, "Disabled")?.note
    #expect(note?.contains("launchctl enable or disable") == true)
  }

  @Test func obsoleteKeysCarryTheManPageNote() {
    var job = daemon
    job.additionalKeys = ["OnDemand": .bool(false), "MachServices": .dictionary([:])]
    let summary = JobExplainer.summarize(job)
    #expect(summary.row(.other, "OnDemand")?.note?.contains("remove it") == true)
    #expect(summary.row(.other, "MachServices")?.note == nil)
  }

  @Test func behaviourNotesFollowTheManPage() {
    var job = daemon
    job.startInterval = 300
    job.keepAlive = KeepAlive(mode: .conditional, successfulExit: false, crashed: true)
    job.throttleInterval = 30
    job.exitTimeOut = 0
    job.nice = 5
    job.standardOutPath = "/Library/Logs/Acme/out.log"
    var summary = JobExplainer.summarize(job)
    #expect(summary.row(.schedule, "Repeats")?.note?.contains("while the job is running") == true)
    #expect(summary.row(.restart, "After Exit")?.note?.contains("Any matching condition") == true)
    #expect(summary.row(.restart, "After Crash")?.note == nil)  // The note appears once per section.
    #expect(summary.row(.restart, "Minimum Gap")?.note?.contains("10 seconds") == true)
    #expect(summary.row(.restart, "Stop Timeout")?.note?.contains("forever") == true)
    #expect(summary.row(.environment, "Priority")?.note?.contains("Process Type is preferred") == true)
    #expect(summary.row(.logging, "Output")?.note?.contains("Created if missing") == true)
    job.exitTimeOut = 20
    summary = JobExplainer.summarize(job)
    #expect(summary.row(.restart, "Stop Timeout")?.note?.contains("SIGTERM") == true)
  }

  @Test func durationsAreExact() {
    #expect(JobExplainer.duration(1) == "1 second")
    #expect(JobExplainer.duration(90) == "90 seconds")
    #expect(JobExplainer.duration(300) == "5 minutes")
    #expect(JobExplainer.duration(7200) == "2 hours")
  }

  @Test func eachSectionLinksToTheTabThatEditsIt() {
    #expect(SummaryTab.tab(for: .program) == .general)
    #expect(SummaryTab.tab(for: .schedule) == .options)
    #expect(SummaryTab.tab(for: .other) == .options)
  }
}
