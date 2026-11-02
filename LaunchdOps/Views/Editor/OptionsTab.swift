import SwiftUI

struct OptionsTab: View {
  @Binding var job: LaunchJob
  /// Rotate Logs, for daemons in package mode; nil hides the switch.
  let rotateLogs: Binding<Bool>?
  let issues: [ValidationIssue]

  private let number = IntegerFormatStyle<Int>().grouping(.never)

  var body: some View {
    Form {
      JobIssuesSection(issues: issues)
      scheduleSection
      CalendarSection(intervals: $job.calendarIntervals)
      KeepAliveSection(keepAlive: $job.keepAlive)
      EnvironmentSection(variables: $job.environment)
      loggingSection
      TextListSection(
        title: "Watch Paths",
        placeholder: "/path/to/watch",
        addTitle: "Add Watch Path",
        footer: "Starts the job when a listed path changes. Apple discourages this because changes can be missed.",
        items: $job.watchPaths
      )
      TextListSection(
        title: "Queue Directories",
        placeholder: "/path/to/queue",
        addTitle: "Add Queue Directory",
        footer: "Keeps the job running while a listed directory is not empty.",
        items: $job.queueDirectories
      )
      lifecycleSection
      if job.context.isAgent {
        sessionSection
      }
      resourcesSection
      TextListSection(
        title: "Associated Bundle Identifiers",
        placeholder: "com.example.app",
        addTitle: "Add Bundle Identifier",
        footer: "Shows the job under this app in System Settings > General > Login Items & Extensions.",
        items: $job.associatedBundleIdentifiers
      )
      AdditionalKeysSection(keys: $job.additionalKeys)
    }
    .formStyle(.grouped)
  }

  private var scheduleSection: some View {
    Section {
      Toggle(isOn: $job.runAtLoad) {
        InfoLabel(
          "Run at Load",
          info: "Starts the job when it is loaded, such as at startup or login.",
          key: "RunAtLoad"
        )
      }
      LabeledContent {
        HStack {
          TextField("Start Interval", value: $job.startInterval, format: number, prompt: Text("Off"))
            .labelsHidden()
            .frame(width: 100)
          Text("seconds")
            .foregroundStyle(.secondary)
        }
      } label: {
        InfoLabel(
          "Start Interval",
          info: "Starts the job every N seconds while the Mac is awake.",
          key: "StartInterval"
        )
      }
      Toggle(isOn: $job.startOnMount) {
        InfoLabel("Start on Mount", info: "Starts the job whenever a file system is mounted.", key: "StartOnMount")
      }
    } header: {
      Text("When to Run")
    } footer: {
      Text(
        "Start Interval skips runs while the Mac is asleep. Apple recommends avoiding Run at Load because it slows startup."
      )
    }
  }

  private var loggingSection: some View {
    Section {
      TextField(text: $job.standardOutPath, prompt: Text("/Library/Logs/Example/output.log")) {
        InfoLabel(
          "Standard Output",
          info: "File that receives what the job prints. Leave empty to discard it.",
          key: "StandardOutPath"
        )
      }
      .monospaced()
      TextField(text: $job.standardErrorPath, prompt: Text("/Library/Logs/Example/error.log")) {
        InfoLabel(
          "Standard Error",
          info: "File that receives the job’s error messages. Leave empty to discard them.",
          key: "StandardErrorPath"
        )
      }
      .monospaced()
      if let rotateLogs {
        Toggle(isOn: rotateLogs) {
          InfoLabel(
            "Rotate Logs",
            info: """
              The package installs a newsyslog rule: macOS keeps 5 compressed copies and starts a new file at \
              10 MB. The uninstall script removes the rule.
              """
          )
        }
      }
    } header: {
      Text("Logging")
    } footer: {
      Text(loggingFooter)
    }
  }

  private var loggingFooter: LocalizedStringKey {
    if rotateLogs != nil {
      return "The install script creates missing log folders. Without Rotate Logs, these files grow without limit."
    }
    if job.context == .daemon && job.keepAlive.mode != .off {
      return """
        A job that keeps running holds its log file open, so it can’t be rotated. For long-running jobs, log to \
        the unified log instead.
        """
    }
    return "launchd creates missing log files but not missing folders. These files are not rotated automatically."
  }

  private var lifecycleSection: some View {
    Section {
      TextField(value: $job.throttleInterval, format: number, prompt: Text("Default 10 seconds")) {
        InfoLabel(
          "Throttle Interval",
          info: "Minimum seconds between starts. launchd waits this long before starting the job again.",
          key: "ThrottleInterval"
        )
      }
      TextField(value: $job.exitTimeOut, format: number, prompt: Text("System default")) {
        InfoLabel(
          "Exit Timeout",
          info: "Seconds between SIGTERM and SIGKILL when the job is stopped.",
          key: "ExitTimeOut"
        )
      }
      TextField(text: $job.umask, prompt: Text("Octal, for example 022")) {
        InfoLabel(
          "Umask",
          info: "Entered as octal. LaunchdOps writes the decimal value launchd expects.",
          key: "Umask"
        )
      }
      .monospaced()
      Toggle(isOn: $job.launchOnlyOnce) {
        InfoLabel(
          "Launch Only Once",
          info: "Runs the job once per startup. Use when it can’t safely run again without a restart.",
          key: "LaunchOnlyOnce"
        )
      }
      Toggle(isOn: $job.abandonProcessGroup) {
        InfoLabel(
          "Abandon Process Group",
          info: "Keeps child processes running after the job exits.",
          key: "AbandonProcessGroup"
        )
      }
    } header: {
      Text("Lifecycle")
    }
  }

  private var sessionSection: some View {
    Section {
      ForEach(SessionType.allCases) { session in
        Toggle(isOn: sessionBinding(session)) {
          InfoLabel(title: session.title, info: session.help, key: "LimitLoadToSessionType")
        }
      }
    } header: {
      Text("Session Types")
    } footer: {
      Text("Where this agent loads, not how much CPU it gets. Leave all off to load only at the desktop login (Aqua).")
    }
  }

  private var resourcesSection: some View {
    Section {
      Picker(selection: $job.processType) {
        Text("Default").tag(ProcessTypeOption?.none)
        ForEach(ProcessTypeOption.allCases) { type in
          Text(type.rawValue).tag(ProcessTypeOption?.some(type))
        }
      } label: {
        InfoLabel("Process Type", modelInfo: ProcessTypeOption.summary, key: "ProcessType")
      }
      TextField(value: $job.nice, format: number, prompt: Text("-20 to 20")) {
        InfoLabel("Nice", info: "Scheduling priority from -20 to 20. Lower numbers get more CPU time.", key: "Nice")
      }
      Toggle(isOn: $job.lowPriorityIO) {
        InfoLabel(
          "Low Priority I/O",
          info: "The kernel treats the job’s file system I/O as low priority.",
          key: "LowPriorityIO"
        )
      }
      Toggle(isOn: $job.lowPriorityBackgroundIO) {
        InfoLabel(
          "Low Priority Background I/O",
          info: "Low-priority file system I/O only while the job is throttled as background work.",
          key: "LowPriorityBackgroundIO"
        )
      }
    } header: {
      Text("Resources")
    } footer: {
      Text("How much CPU and I/O the job gets, not where it loads. Apple recommends Process Type over Nice.")
    }
  }

  private func sessionBinding(_ session: SessionType) -> Binding<Bool> {
    Binding(
      get: { job.sessionTypes.contains(session.rawValue) },
      set: { isOn in
        if isOn {
          if !job.sessionTypes.contains(session.rawValue) {
            job.sessionTypes.append(session.rawValue)
          }
        } else {
          job.sessionTypes.removeAll { $0 == session.rawValue }
        }
      }
    )
  }
}
