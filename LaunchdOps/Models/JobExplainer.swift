import Foundation

/// The Summary tab's account of a job's plist: a one-sentence headline, then only the keys the plist contains,
/// grouped in plist order, each row naming its key. Unset keys are left out. Notes explain launchd behaviour that
/// isn't obvious from the value, following launchd.plist(5).
struct JobSummary: Equatable, Sendable {
  enum Topic: String, CaseIterable, Sendable {
    case general, program, schedule, restart, logging, environment, other

    var title: String {
      switch self {
      case .general: "General"
      case .program: "Program & Arguments"
      case .schedule: "Schedule"
      case .restart: "Keep Alive & Restart"
      case .logging: "Logging"
      case .environment: "Environment & Limits"
      case .other: "Other Keys"
      }
    }

    /// SF Symbol for the section header.
    var systemImage: String {
      switch self {
      case .general: "tag"
      case .program: "apple.terminal"
      case .schedule: "clock"
      case .restart: "arrow.clockwise"
      case .logging: "list.bullet.rectangle"
      case .environment: "slider.horizontal.3"
      case .other: "ellipsis.curlybraces"
      }
    }
  }

  struct Row: Equatable, Identifiable, Sendable {
    /// What the row is, in plain words.
    let label: String
    /// The plist key the value comes from; nil only for the derived command line.
    let key: String?
    let value: String
    /// Paths, labels and command lines are shown monospaced and selectable.
    let isCode: Bool
    /// A short note on launchd behaviour, only where the value alone would mislead.
    let note: String?

    var id: String { "\(label)|\(key ?? "")|\(value)" }

    init(_ label: String, key: String?, _ value: String, code: Bool = false, note: String? = nil) {
      self.label = label
      self.key = key
      self.value = value
      self.isCode = code
      self.note = note
    }
  }

  struct Section: Equatable, Identifiable, Sendable {
    let topic: Topic
    let rows: [Row]
    var id: Topic { topic }
  }

  /// Plain text with the program name in a Markdown code span, for copying and tests.
  let headline: String
  /// The same sentence for display, with the program name styled as code. Built from runs rather than parsed
  /// Markdown, so characters in the name are shown as typed.
  let styledHeadline: AttributedString
  /// Only sections with at least one key in the plist.
  let sections: [Section]

  func section(_ topic: Topic) -> Section? {
    sections.first { $0.topic == topic }
  }

  func row(_ topic: Topic, _ label: String) -> Row? {
    section(topic)?.rows.first { $0.label == label }
  }
}

enum JobExplainer {
  static func summarize(_ job: LaunchJob) -> JobSummary {
    let sections: [JobSummary.Section] = [
      .init(topic: .general, rows: general(job)),
      .init(topic: .program, rows: program(job)),
      .init(topic: .schedule, rows: schedule(job)),
      .init(topic: .restart, rows: restart(job)),
      .init(topic: .logging, rows: logging(job)),
      .init(topic: .environment, rows: environment(job)),
      .init(topic: .other, rows: other(job)),
    ]
    let headline = headline(job)
    return JobSummary(
      headline: headline.markdown,
      styledHeadline: headline.styled,
      sections: sections.filter { !$0.rows.isEmpty }
    )
  }

  // MARK: - Headline

  private static func headline(_ job: LaunchJob) -> (markdown: String, styled: AttributedString) {
    let executable = job.executablePath
    guard !executable.isEmpty else {
      let text = "The plist has no program yet, so this job has nothing to run."
      return (text, AttributedString(text))
    }
    let name = (executable as NSString).lastPathComponent
    let who =
      switch job.context {
      case .daemon: job.userName.isEmpty ? "as root" : "as \(job.userName)"
      case .globalAgent: "for each user who logs in"
      case .userAgent: "for one user"
      }
    var when: [String] = []
    if job.runAtLoad || job.keepAlive.mode != .off {
      when.append(job.context == .daemon ? "at startup" : "at login")
    }
    if let interval = job.startInterval, interval > 0 {
      when.append("every \(duration(interval))")
    }
    when += job.calendarIntervals.map {
      $0.summary.replacingOccurrences(of: "Runs ", with: "").trimmingCharacters(in: ["."])
    }
    if !job.watchPaths.isEmpty { when.append("when a watched path changes") }
    if !job.queueDirectories.isEmpty { when.append("while a queue folder has files") }
    if job.startOnMount { when.append("when a volume mounts") }
    let start = when.isEmpty ? "only when started by hand" : when.joined(separator: " and ")
    let restart =
      switch job.keepAlive.mode {
      case .off: "Not restarted if it stops."
      case .always: "Restarted whenever it exits."
      case .conditional: "Restarted when its Keep Alive conditions match."
      }
    let disabled = job.disabled ? " Disabled until enabled with launchctl." : ""
    let rest = " \(who) \(start). \(restart)\(disabled)"
    var code = AttributedString(name)
    code.inlinePresentationIntent = .code
    return ("Runs `\(name)`\(rest)", AttributedString("Runs ") + code + AttributedString(rest))
  }

  // MARK: - Sections (only keys the plist contains)

  private static func general(_ job: LaunchJob) -> [JobSummary.Row] {
    var rows: [JobSummary.Row] = []
    if !job.label.isEmpty {
      rows.append(.init("Name", key: "Label", job.label, code: true))
    }
    if job.disabled {
      let note = "Only the default: launchctl enable or disable overrides it, and that state is kept outside the plist."
      rows.append(.init("Disabled", key: "Disabled", "Yes", note: note))
    }
    let bundles = job.associatedBundleIdentifiers.map(\.value).filter { !$0.isEmpty }
    if !bundles.isEmpty {
      let note = "Listed under this app in Login Items & Extensions."
      let row = JobSummary.Row(
        "Shown Under App", key: "AssociatedBundleIdentifiers", bundles.joined(separator: ", "), code: true, note: note
      )
      rows.append(row)
    }
    return rows
  }

  private static func program(_ job: LaunchJob) -> [JobSummary.Row] {
    var rows: [JobSummary.Row] = []
    let arguments = job.argumentValues
    // What launchd executes: Program when set (ProgramArguments[0] is then only the process name), else
    // ProgramArguments[0]; the other arguments follow in order.
    let executable = job.executablePath
    if !executable.isEmpty {
      let command = ([executable] + arguments.dropFirst()).map(terminalWord).joined(separator: " ")
      var note = "launchd runs this directly, not through a shell. Quotes only show where an argument begins and ends."
      if !job.program.isEmpty, let first = arguments.first, !first.isEmpty, first != job.program {
        note +=
          first.hasPrefix("-")
          ? " \(first) isn’t passed to the program: with Program set, the first argument is only the process name."
          : " The process is named \((first as NSString).lastPathComponent)."
      }
      let key = job.program.isEmpty ? "ProgramArguments" : "Program + ProgramArguments"
      rows.append(.init("Command Line", key: key, command, code: true, note: note))
    }
    if let script = shellScript(executable: executable, arguments: Array(arguments.dropFirst())) {
      let note = "Runs through the shell, so $VARIABLES, ~, pipes and && work in this script."
      rows.append(.init("Shell Script", key: "ProgramArguments", script, code: true, note: note))
    }
    // UserName and GroupName only apply to services in the system domain; InitGroups is ignored without UserName.
    let agentNote = job.context == .daemon ? nil : "Ignored for agents; only daemons run as another user."
    if !job.userName.isEmpty {
      rows.append(.init("Runs As", key: "UserName", job.userName, note: agentNote))
    }
    if !job.groupName.isEmpty {
      rows.append(.init("Group", key: "GroupName", job.groupName, note: agentNote))
    }
    if let initGroups = job.initGroups {
      let note =
        job.context != .daemon || job.userName.isEmpty
        ? "Ignored unless a daemon sets Runs As." : nil
      rows.append(.init("Initialize Groups", key: "InitGroups", initGroups ? "Yes" : "No", note: note))
    }
    if !job.workingDirectory.isEmpty {
      rows.append(.init("Working Folder", key: "WorkingDirectory", job.workingDirectory, code: true))
    }
    if !job.sessionTypes.isEmpty {
      let note = job.context == .daemon ? "Has no effect on daemons: the system context has no sessions." : nil
      rows.append(
        .init("Sessions", key: "LimitLoadToSessionType", job.sessionTypes.joined(separator: ", "), note: note))
    }
    return rows
  }

  /// An argument as it would be typed in Terminal: quoted only when it has spaces or shell characters.
  static func terminalWord(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0) }
    return plain ? value : Shell.quoted(value)
  }

  /// The script of `sh`, `bash` or `zsh` started with `-c`, which is what really runs.
  private static func shellScript(executable: String, arguments: [String]) -> String? {
    let shells: Set = ["sh", "bash", "zsh"]
    guard shells.contains((executable as NSString).lastPathComponent),
      // -c, or combined single-letter options ending in c such as -lc.
      let flag = arguments.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c") }),
      arguments.indices.contains(flag + 1)
    else { return nil }
    return arguments[flag + 1]
  }

  private static func schedule(_ job: LaunchJob) -> [JobSummary.Row] {
    var rows: [JobSummary.Row] = []
    if job.runAtLoad {
      let moment = job.context == .daemon ? "At startup and when installed" : "At login and when installed"
      rows.append(.init("Run at Load", key: "RunAtLoad", moment))
    }
    if let interval = job.startInterval, interval > 0 {
      let note = "Skipped while the Mac sleeps or while the job is running. Independent of any calendar schedule."
      rows.append(.init("Repeats", key: "StartInterval", "Every \(duration(interval))", note: note))
    }
    for (index, interval) in job.calendarIntervals.enumerated() {
      let text = interval.summary.replacingOccurrences(of: "Runs ", with: "").trimmingCharacters(in: ["."])
      let label = job.calendarIntervals.count == 1 ? "Calendar" : "Calendar \(index + 1)"
      let value = text.prefix(1).uppercased() + text.dropFirst()
      rows.append(.init(label, key: "StartCalendarInterval", value, note: calendarNote))
    }
    for path in job.watchPaths.map(\.value) where !path.isEmpty {
      rows.append(.init("Watched Path", key: "WatchPaths", path, code: true, note: "Changes can be missed."))
    }
    for path in job.queueDirectories.map(\.value) where !path.isEmpty {
      let note = "Runs while it isn’t empty."
      rows.append(.init("Queue Folder", key: "QueueDirectories", path, code: true, note: note))
    }
    if job.startOnMount {
      rows.append(.init("On Mount", key: "StartOnMount", "Whenever a volume is mounted"))
    }
    if job.launchOnlyOnce {
      rows.append(.init("Once Only", key: "LaunchOnlyOnce", "At most once until the Mac restarts"))
    }
    return rows
  }

  private static let calendarNote =
    "Runs on wake if the Mac was asleep; several missed runs become one. Independent of Repeats."

  private static let conditionalKeepAliveNote =
    "Any matching condition keeps it alive. It also starts at load, and with no match it starts only on demand."

  private static func addNote(_ note: String, toRowAt index: Int, in rows: inout [JobSummary.Row]) {
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    rows[index] = .init(row.label, key: row.key, row.value, code: row.isCode, note: note)
  }

  private static func restart(_ job: LaunchJob) -> [JobSummary.Row] {
    var rows: [JobSummary.Row] = []
    let keepAlive = job.keepAlive
    switch keepAlive.mode {
    case .off:
      break
    case .always:
      let note = "Also starts it at load."
      rows.append(.init("Keep Alive", key: "KeepAlive", "Always, restarted whenever it exits", note: note))
    case .conditional:
      let first = rows.count
      defer { addNote(conditionalKeepAliveNote, toRowAt: first, in: &rows) }
      if let successful = keepAlive.successfulExit {
        let value = successful ? "Restart after a successful exit (0)" : "Restart after a failed exit"
        rows.append(.init("After Exit", key: "KeepAlive ▸ SuccessfulExit", value))
      }
      if let crashed = keepAlive.crashed {
        rows.append(.init("After Crash", key: "KeepAlive ▸ Crashed", crashed ? "Restart" : "Restart unless it crashed"))
      }
      for state in keepAlive.pathStates where !state.path.isEmpty {
        let label = state.keepAliveWhenExists ? "While Exists" : "While Missing"
        rows.append(.init(label, key: "KeepAlive ▸ PathState", state.path, code: true))
      }
      for name in keepAlive.otherKeys.keys.sorted() {
        let value = keepAlive.otherKeys[name]?.summary ?? ""
        rows.append(.init(name, key: "KeepAlive ▸ \(name)", value, note: keepAliveKeyNotes[name]))
      }
    }
    if let throttle = job.throttleInterval {
      let note = "Between starts. Without this key launchd starts a job at most once every 10 seconds."
      rows.append(.init("Minimum Gap", key: "ThrottleInterval", duration(throttle), note: note))
    }
    if let timeout = job.exitTimeOut {
      let note =
        timeout == 0
        ? "Zero means wait forever, which can stall shutdown."
        : "launchd sends SIGTERM, then SIGKILL after this time."
      rows.append(.init("Stop Timeout", key: "ExitTimeOut", duration(timeout), note: note))
    }
    if job.abandonProcessGroup {
      rows.append(.init("Child Processes", key: "AbandonProcessGroup", "Keep running after it exits"))
    }
    return rows
  }

  private static func logging(_ job: LaunchJob) -> [JobSummary.Row] {
    var rows: [JobSummary.Row] = []
    if !job.standardOutPath.isEmpty {
      rows.append(.init("Output", key: "StandardOutPath", job.standardOutPath, code: true, note: logFileNote))
    }
    if !job.standardErrorPath.isEmpty {
      rows.append(.init("Errors", key: "StandardErrorPath", job.standardErrorPath, code: true, note: logFileNote))
    }
    return rows
  }

  private static let logFileNote =
    "Created if missing, owned by the Runs As user and Group if set, with permissions from File Permissions if set."

  private static func environment(_ job: LaunchJob) -> [JobSummary.Row] {
    var rows: [JobSummary.Row] = job.environment.filter { !$0.name.isEmpty }.map {
      .init($0.name, key: "EnvironmentVariables", "Value hidden")
    }
    if !job.umask.isEmpty {
      rows.append(.init("File Permissions", key: "Umask", job.umask, code: true))
    }
    if let processType = job.processType {
      rows.append(.init("Process Type", key: "ProcessType", processType.rawValue, note: processType.help))
    }
    if let nice = job.nice {
      let note = "Process Type is preferred over Nice and resource limits."
      rows.append(.init("Priority", key: "Nice", "\(nice)", note: note))
    }
    if job.lowPriorityIO {
      rows.append(.init("Disk Access", key: "LowPriorityIO", "Low priority"))
    }
    if job.lowPriorityBackgroundIO {
      rows.append(.init("Background Disk Access", key: "LowPriorityBackgroundIO", "Low priority"))
    }
    return rows
  }

  /// Keys LaunchdOps doesn't edit, kept exactly as imported.
  private static func other(_ job: LaunchJob) -> [JobSummary.Row] {
    job.additionalKeys.keys.sorted().map { name in
      let value = job.additionalKeys[name].map { "\($0.typeName): \($0.summary)" } ?? ""
      return .init(name, key: name, value, note: otherKeyNotes[name])
    }
  }

  private static let keepAliveKeyNotes: [String: String] = [
    "NetworkState": "No longer implemented.",
    "OtherJobEnabled": "Only checks that the other job is loaded, not that it is running.",
  ]

  /// What launchd.plist(5) says about keys it no longer honours or that behave unexpectedly.
  static let otherKeyNotes: [String: String] = [
    "OnDemand": "Does nothing when true; false is the same as KeepAlive true. launchd.plist(5) says to remove it.",
    "ServiceIPC": "launchd.plist(5) says to remove this key.",
    "TimeOut": "No longer implemented. Use EnablePressuredExit to let the system reclaim an idle job.",
    "LimitLoadToHosts": "No longer supported.",
    "LimitLoadFromHosts": "No longer supported.",
    "EnablePressuredExit": "Ignored when KeepAlive is true. The job ignores SIGTERM unless it handles it itself.",
    "RootDirectory": "launchd changes to this folder with chroot(2) before running the job.",
  ]

  // MARK: - Formatting

  /// "10 seconds", "5 minutes", "2 hours"; exact, never rounded.
  static func duration(_ seconds: Int) -> String {
    var value = seconds
    var unit = "second"
    if seconds >= 3600 && seconds % 3600 == 0 {
      (value, unit) = (seconds / 3600, "hour")
    } else if seconds >= 60 && seconds % 60 == 0 {
      (value, unit) = (seconds / 60, "minute")
    }
    return "\(value) \(unit)\(value == 1 ? "" : "s")"
  }
}
