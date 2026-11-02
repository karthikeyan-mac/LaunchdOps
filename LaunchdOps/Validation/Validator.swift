import Foundation

enum Validator {
  static func validate(_ project: Project) -> [ValidationIssue] {
    let project = project.resolved()
    var issues: [ValidationIssue] = []
    issues += projectIssues(project)
    issues += payloadIssues(project)
    for job in project.jobs {
      issues += jobIssues(job, in: project)
    }
    var seen = Set<String>()
    return issues
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.severity > $1.severity }
  }

  static func isValidLabel(_ label: String) -> Bool {
    label.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) != nil
  }

  // MARK: - Project

  private static func installerPackageIssues(_ project: Project) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    let identity = project.settings.signingIdentity
    if project.settings.notarizeAfterExport && !identity.isEmpty && !identity.hasPrefix("Developer ID Installer:") {
      let message = "Apple notarizes only packages signed with a Developer ID Installer identity. Choose one in "
        + "Settings ▸ Signing, or turn off Notarize After Export."
      issues.append(ValidationIssue("package.notarize-identity", .error, message, source: .packaging))
    }
    if project.settings.signingIdentity.isEmpty {
      let message =
        "The installer package will be unsigned. Many MDMs and Apple's InstallEnterpriseApplication command "
        + "need a Developer ID Installer signature; choose a signing identity in LaunchdOps ▸ Settings."
      issues.append(ValidationIssue("package.unsigned", .warning, message, source: .packaging))
    }
    let plists = project.packagedPlists.map { ($0.path, Data(), 0o644) }
    let payload = project.payload.map { (project.installPath(for: $0), Data(), $0.mode) }
    let rotation = LogRotation.configFile(for: project).map { [($0.path, Data(), 0o644)] } ?? []
    do {
      let entryCount = try PackagePayload.entries(files: plists + payload + rotation).count
      if entryCount > BomWriter.maximumEntries {
        let message =
          "The package would contain \(entryCount) files and folders; LaunchdOps can write at most "
          + "\(BomWriter.maximumEntries). Choose Build Script output instead."
        issues.append(ValidationIssue("package.too-many-files", .error, message, source: .packaging))
      }
    } catch {
      issues.append(ValidationIssue("package.paths", .error, error.localizedDescription, source: .packaging))
    }
    return issues
  }

  private static func projectIssues(_ project: Project) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    let settings = project.settings

    if project.jobs.isEmpty {
      issues.append(.init("project.no-jobs", .info, "Add a launch daemon or agent to get started.", source: .packaging))
    }

    let labels = project.jobs.map(\.label).filter { !$0.isEmpty }
    for label in Set(labels) where labels.filter({ $0 == label }).count > 1 {
      for job in project.jobs where job.label == label {
        issues.append(.init(
          "label.duplicate", .error,
          "The label \(label) is used by more than one job. Each job needs a unique label.",
          source: .launchdPlist, job: job.id
        ))
      }
    }

    for retired in settings.retiredLabels {
      if !isValidLabel(retired) {
        issues.append(.init(
          "retired.invalid", .error,
          "Retired label \"\(retired)\" contains characters that are not allowed.",
          source: .packaging, detail: retired
        ))
      } else if labels.contains(retired) {
        issues.append(.init(
          "retired.current", .warning,
          "\(retired) is listed as retired but is still a job in this project. The upgrade script will remove it.",
          source: .packaging, detail: retired
        ))
      }
    }

    switch settings.mode {
    case .package:
      if !isValidLabel(settings.packageIdentifier) || !settings.packageIdentifier.contains(".") {
        issues.append(.init(
          "package.identifier", .error,
          "Enter a reverse-DNS package identifier, for example com.example.pkg.backup.",
          source: .packaging, blocking: !isValidLabel(settings.packageIdentifier)
        ))
      }
      if settings.version.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) == nil {
        issues.append(.init(
          "package.version", .error,
          "Enter a numeric package version such as 1.0 or 2.1.3.",
          source: .packaging
        ))
      }
      if settings.includePackage && settings.packageOutput == .installerPackage {
        issues.append(contentsOf: installerPackageIssues(project))
      }
    case .declarative:
      if !isValidLabel(settings.taskType) || !settings.taskType.contains(".") {
        issues.append(.init(
          "ddm.task-type", .error,
          "DDM background tasks need a reverse-DNS task type.",
          source: .backgroundTasks, blocking: !isValidLabel(settings.taskType)
        ))
      } else if let daemon = project.daemons.first, daemon.label != settings.taskType {
        // Some MDMs require the task type to equal the daemon label (for example Jamf Pro Blueprints; see Der Flounder's DDM background task walkthrough, 2025-06-10).
        let message =
          "The task type \(settings.taskType) differs from the daemon label \(daemon.label). Some MDMs require "
          + "them to match; click Use Daemon Label on the Export tab."
        issues.append(.init("ddm.task-type-label", .warning, message, source: .backgroundTasks))
      }
      issues.append(.init(
        "ddm.requirements", .info,
        "DDM background tasks require macOS 15 or later and supervised enrollment.",
        source: .backgroundTasks
      ))
    }
    return issues
  }

  // MARK: - Payload

  private static func payloadIssues(_ project: Project) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    var installPaths: [String: Int] = [:]

    for file in project.payload {
      let path = project.installPath(for: file)
      installPaths[path, default: 0] += 1

      if let problem = SafeInstallPath.problem(withName: file.name) {
        issues.append(.init(
          "payload.name", .error,
          "The payload file name \"\(file.name)\" \(problem.message). Rename the file and add it again.",
          source: .security, detail: file.id.uuidString, blocking: true
        ))
      }
      let destinationProblem =
        project.settings.mode == .package
        ? SafeInstallPath.problem(withFolder: file.destination)
        : SafeInstallPath.problem(withSubfolder: file.destination)
      if let destinationProblem {
        issues.append(.init(
          "payload.destination", .error,
          "The destination for \(file.name) \(destinationProblem.message).",
          source: .security, detail: file.id.uuidString, blocking: true
        ))
      }
      if file.mode & 0o022 != 0 {
        issues.append(.init(
          "payload.writable", .error,
          "\(file.name) is writable by users other than root. A job could be hijacked by modifying it.",
          source: .security, detail: file.id.uuidString, blocking: true
        ))
      }

      issues += binaryIssues(file, project: project)

      if project.settings.mode == .package {
        let protected = ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec"]
        if protected.contains(where: { file.destination == $0 || file.destination.hasPrefix($0 + "/") }) {
          issues.append(.init(
            "payload.sip", .error,
            "\(file.destination) is protected by System Integrity Protection. Use /usr/local or /Library instead.",
            source: .packaging, detail: file.id.uuidString
          ))
        }
        if isUserWritableLocation(file.destination) {
          issues.append(.init(
            "payload.user-location", .error,
            "\(file.name) installs to a user-writable location. Jobs must run code only from root-owned folders.",
            source: .security, detail: file.id.uuidString
          ))
        }
      }
    }

    for (path, count) in installPaths where count > 1 {
      issues.append(.init(
        "payload.duplicate", .error,
        "More than one payload file installs to \(path).",
        source: .packaging, detail: path
      ))
    }
    issues.append(contentsOf: payloadSizeIssues(project))
    return issues
  }

  /// Payloads are for the script or tool a job runs. Large ones are held in memory while editing and exporting,
  /// so LaunchdOps slows down; apps and large software belong in their own deployment.
  static let payloadWarningSize = 200 * 1024 * 1024
  static let payloadErrorSize = 1024 * 1024 * 1024

  private static func payloadSizeIssues(_ project: Project) -> [ValidationIssue] {
    let total = project.payload.reduce(0) { $0 + $1.contents.count }
    guard total > payloadWarningSize else { return [] }
    let size = Int64(total).formatted(.byteCount(style: .file))
    let advice = "Deploy apps and large software separately, then set Program to their installed path."
    let isError = total > payloadErrorSize
    let message =
      isError
      ? "The payload is \(size), over the 1 GB limit. Payloads are for the script or tool the job runs. \(advice)"
      : "The payload is \(size). Large payloads make editing, exporting and notarizing slow. \(advice)"
    let issue = ValidationIssue(
      "payload.total-size",
      isError ? .error : .warning,
      message,
      source: .packaging
    )
    return [issue]
  }

  /// Unsigned programs don't run on Apple silicon, and Apple's notary service rejects a package holding a program
  /// that isn't signed with a Developer ID and the hardened runtime. The certificate and secure timestamp inside the
  /// signature aren't checked.
  private static func binaryIssues(_ file: PayloadFile, project: Project) -> [ValidationIssue] {
    let intendsToNotarize = project.settings.mode == .package && !project.settings.signingIdentity.isEmpty
    let rule: String
    let message: String
    switch MachOSignature.inspect(file.contents) {
    case .unsigned(let arm64):
      rule = "payload.binary-unsigned"
      let effect =
        arm64
        ? "Apple silicon Macs won’t run its arm64 code"
        : "Apple silicon Macs can run this Intel program only through Rosetta"
      message =
        "\(file.name) is a program with no code signature. \(effect), and Apple’s notary service rejects packages "
        + "that contain it. Sign it with a Developer ID Application identity before adding it."
    case .adHoc where intendsToNotarize:
      rule = "payload.binary-notarization"
      message =
        "\(file.name) is signed ad hoc, so Apple’s notary service will reject the package. Sign it with a "
        + "Developer ID Application identity, the hardened runtime and a secure timestamp."
    case .developerSigned(hardenedRuntime: false) where intendsToNotarize:
      rule = "payload.binary-notarization"
      message =
        "\(file.name) is signed without the hardened runtime, so Apple’s notary service will reject the package. "
        + "Sign it again with the hardened runtime and a secure timestamp."
    case .notMachO, .adHoc, .developerSigned:
      return []
    }
    return [ValidationIssue(rule, .warning, message, source: .notarization, detail: file.id.uuidString)]
  }

  // MARK: - Jobs

  private static func jobIssues(_ job: LaunchJob, in project: Project) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    func add(
      _ rule: String,
      _ severity: IssueSeverity,
      _ message: String,
      _ source: IssueSource,
      detail: String = ""
    ) {
      issues.append(.init(rule, severity, message, source: source, job: job.id, detail: detail))
    }
    /// For labels, which become file names and script values: Export Anyway can't override these.
    func addBlocking(_ rule: String, _ message: String) {
      issues.append(.init(rule, .error, message, source: .launchdPlist, job: job.id, blocking: true))
    }

    if job.label.isEmpty {
      addBlocking("label.missing", "Label is required.")
    } else if !isValidLabel(job.label) {
      let message =
        "Use only letters, numbers, dots, hyphens and underscores in the label. It is also used as the file name."
      addBlocking("label.characters", message)
    } else {
      if !job.label.contains(".") {
        add("label.reverse-dns", .warning, "Use a reverse-DNS label such as com.example.backup.", .launchdPlist)
      }
      if job.label.lowercased().hasPrefix("com.apple.") {
        add("label.apple", .warning, "Labels starting with com.apple. are reserved for Apple.", .launchdPlist)
      }
    }

    programIssues(job, in: project, add: add)
    contextIssues(job, in: project, add: add)
    triggerIssues(job, add: add)
    lifecycleIssues(job, add: add)
    pathIssues(job, add: add)
    logRotationIssues(job, in: project, add: add)
    backgroundTaskIssues(job, in: project, add: add)
    secretIssues(job, add: add)
    additionalKeyIssues(job, add: add)
    return issues
  }

  private static func programIssues(
    _ job: LaunchJob,
    in project: Project,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    let arguments = job.argumentValues
    if job.program.isEmpty && arguments.isEmpty {
      add("program.missing", .error, "Set a program or at least one program argument.", .launchdPlist, "")
      return
    }
    // With Program set, ProgramArguments is the whole argv: its first item is only the process name.
    if !job.program.isEmpty, let first = arguments.first, first.hasPrefix("-") {
      add("program.argv0-option", .warning,
          "\(first) is the first argument, which launchd passes as the process name when Program is set, so the "
            + "program never receives it. Make the program path the first argument, or clear Program.",
          .launchdPlist, "")
    }
    if !job.program.isEmpty && !job.program.hasPrefix("/") {
      add("program.relative", .error, "Program must be an absolute path.", .launchdPlist, "")
    }
    if job.program.isEmpty, let first = arguments.first, !first.isEmpty, !first.hasPrefix("/") {
      add("arguments.relative", .warning,
          "\(first) is not an absolute path. launchd resolves it using the standard PATH, which is fragile.",
          .launchdPlist, "")
    }

    let executable = job.executablePath
    if job.context != .userAgent && isUserWritableLocation(executable) {
      add("program.user-writable", .error,
          "\(executable) is in a user-writable location. Anyone who can change it can run code as this job.",
          .security, "")
    } else if job.context == .daemon, project.settings.mode == .package, executable.hasPrefix("/"),
      !isSystemLocation(executable), !project.payload.contains(where: { project.installPath(for: $0) == executable })
    {
      // A root job's program must be owned by root all the way up; only macOS's own folders and files this
      // package installs are known to be. /usr/local, /Applications and /Library/<vendor> depend on the Mac.
      let message =
        "LaunchdOps can’t check who owns \(executable) on your Macs. Make sure the program and every folder above "
        + "it are owned by root and not writable by other users, or install it as a payload file."
      add("program.location-unverified", .info, message, .security, "")
    }

    let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "sh", "bash", "zsh"]
    let usesShell = shells.contains(executable) && arguments.contains("-c")
    if !usesShell {
      let metacharacters: [Character] = ["$", "`", "|", ">", "<", ";", "*"]
      for (index, argument) in arguments.enumerated()
      where argument.hasPrefix("~") || argument.contains(where: { metacharacters.contains($0) }) || argument.contains("&&") {
        add("arguments.shell", .warning,
            "Argument \"\(argument)\" uses shell syntax. launchd does not expand ~, variables, pipes or wildcards.",
            .launchdPlist, String(index))
      }
    }

    if let file = project.payload.first(where: { project.installPath(for: $0) == executable }), !file.isExecutable {
      add("program.not-executable", .error,
          "\(file.name) is used as the program but its mode (\(file.modeString)) is not executable.",
          .packaging, "")
    }

    // Apple's declaration doesn't restrict program paths, but only files inside the task folder are delivered by
    // the task and tamper-resistant. macOS's own programs (such as /bin/zsh) are fine; a script passed to them isn't.
    if project.settings.mode == .declarative, !executable.isEmpty {
      let root = "\(Project.servicesRoot)/\(project.settings.taskType)/"
      let alternateRoot = root.replacingOccurrences(of: "/private/var/", with: "/var/")
      let systemFolders = ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/"]
      let paths = [executable] + job.argumentValues.dropFirst().filter { $0.hasPrefix("/") }
      for path in paths
      where !path.hasPrefix(root) && !path.hasPrefix(alternateRoot) && !systemFolders.contains(where: path.hasPrefix) {
        let message =
          "\(path) is outside this background task’s folder, so the task doesn’t deliver it and it isn’t "
          + "tamper-resistant. Install it another way first (for example with a package), or add it as a payload "
          + "file and choose Use as Program."
        add("ddm.program-location", .warning, message, .backgroundTasks, path)
      }
    }
  }

  private static func contextIssues(
    _ job: LaunchJob,
    in project: Project,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    if job.context.isAgent && (!job.userName.isEmpty || !job.groupName.isEmpty || job.initGroups != nil) {
      add("context.agent-user", .warning,
          "UserName, GroupName and InitGroups only apply to daemons. launchd ignores them for agents.",
          .launchdPlist, "")
    }
    if job.context == .daemon && !job.sessionTypes.isEmpty {
      add("context.daemon-session", .warning,
          "LimitLoadToSessionType only applies to agents. There are no sessions in the system domain.",
          .launchdPlist, "")
    }
    if job.context == .userAgent {
      switch project.settings.mode {
      case .package:
        add("context.user-agent", .info,
            "The package installs this agent in the logged-in user’s ~/Library/LaunchAgents and loads it. If "
              + "nobody is logged in, it isn’t installed, and other users don’t get it; to cover every user, make "
              + "it a Launch Agent (All Users).",
            .packaging, "")
      case .declarative:
        add("ddm.user-agent", .error,
            "DDM background tasks support daemons and agents for all users, not per-user agents.",
            .backgroundTasks, "")
      }
    }
  }

  private static func triggerIssues(
    _ job: LaunchJob,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    let demandKeys = ["MachServices", "Sockets", "LaunchEvents"]
    let hasTrigger = job.runAtLoad
      || job.startInterval != nil
      || !job.calendarIntervals.isEmpty
      || !job.watchPaths.isEmpty
      || !job.queueDirectories.isEmpty
      || job.startOnMount
      || job.keepAlive.mode != .off
      || demandKeys.contains { job.additionalKeys[$0] != nil }
    if !hasTrigger {
      add("trigger.none", .warning,
          "Nothing starts this job. Add a schedule, RunAtLoad or KeepAlive, or it only runs when kickstarted.",
          .launchdPlist, "")
    }
    if job.runAtLoad {
      add("trigger.run-at-load", .info,
          "Apple recommends avoiding RunAtLoad because speculative launches slow startup and login.",
          .launchdPlist, "")
    }
    if let interval = job.startInterval {
      if interval <= 0 {
        add("interval.invalid", .error, "StartInterval must be greater than zero.", .launchdPlist, "")
      } else if interval < 10 {
        add("interval.throttled", .warning,
            "launchd spawns a job at most once every 10 seconds by default, so intervals under 10 seconds are throttled.",
            .launchdPlist, "")
      }
    }

    for (index, interval) in job.calendarIntervals.enumerated() {
      let ranges: [(String, Int?, ClosedRange<Int>)] = [
        ("Minute", interval.minute, 0...59),
        ("Hour", interval.hour, 0...23),
        ("Day", interval.day, 1...31),
        ("Weekday", interval.weekday, 0...7),
        ("Month", interval.month, 1...12)
      ]
      for (name, value, range) in ranges {
        if let value, !range.contains(value) {
          add("calendar.range", .error,
              "\(name) must be between \(range.lowerBound) and \(range.upperBound).",
              .launchdPlist, "\(index)-\(name)")
        }
      }
      if interval.isEmpty {
        add("calendar.empty", .warning,
            "An empty calendar interval matches every minute.", .launchdPlist, "\(index)-empty")
      }
      if interval.day != nil && interval.weekday != nil {
        add("calendar.day-weekday", .info,
            "When both Day and Weekday are set, the job runs if either one matches.",
            .launchdPlist, "\(index)-either")
      }
    }

    if !job.watchPaths.isEmpty {
      add("watch-paths.discouraged", .warning,
          "Apple discourages WatchPaths because file system monitoring can miss changes.",
          .launchdPlist, "")
    }

    switch job.keepAlive.mode {
    case .conditional:
      if !job.keepAlive.hasConditions {
        add("keep-alive.empty", .warning,
            "KeepAlive is conditional but no conditions are set.", .launchdPlist, "")
      }
      if job.keepAlive.otherKeys["NetworkState"] != nil {
        add("keep-alive.network-state", .warning,
            "KeepAlive NetworkState is no longer implemented.", .launchdPlist, "")
      }
      if job.keepAlive.otherKeys["OtherJobEnabled"] != nil {
        add("keep-alive.other-job", .warning,
            "Apple discourages KeepAlive OtherJobEnabled. It only checks whether the other job is loaded.",
            .launchdPlist, "")
      }
      if !job.keepAlive.pathStates.isEmpty {
        add("keep-alive.path-state", .info,
            "Apple recommends IPC over KeepAlive PathState because file system checks can race.",
            .launchdPlist, "")
      }
    case .always:
      if job.additionalKeys["EnablePressuredExit"] != nil {
        add("keep-alive.pressured-exit", .warning,
            "launchd ignores EnablePressuredExit when KeepAlive is always on.", .launchdPlist, "")
      }
    case .off:
      break
    }
  }

  private static func lifecycleIssues(
    _ job: LaunchJob,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    if job.exitTimeOut == 0 {
      add("exit-timeout.zero", .error,
          "An ExitTimeOut of 0 means wait forever and can stall shutdown.", .launchdPlist, "")
    }
    if let throttle = job.throttleInterval, throttle < 0 {
      add("throttle.negative", .error, "ThrottleInterval cannot be negative.", .launchdPlist, "")
    }
    if !job.umask.isEmpty {
      if let value = Int(job.umask.trimmingCharacters(in: .whitespaces), radix: 8) {
        if value > 0o777 {
          add("umask.range", .error, "Umask must be between 000 and 777.", .launchdPlist, "")
        }
      } else {
        add("umask.octal", .error, "Enter Umask as an octal value such as 022.", .launchdPlist, "")
      }
    }
    if let nice = job.nice, !(-20...20).contains(nice) {
      add("nice.range", .error, "Nice must be between -20 and 20.", .launchdPlist, "")
    }
  }

  private static func pathIssues(
    _ job: LaunchJob,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    var absolutePaths: [(String, String)] = [
      ("WorkingDirectory", job.workingDirectory),
      ("StandardOutPath", job.standardOutPath),
      ("StandardErrorPath", job.standardErrorPath)
    ]
    absolutePaths += job.watchPaths.map { ("WatchPaths", $0.value) }
    absolutePaths += job.queueDirectories.map { ("QueueDirectories", $0.value) }
    absolutePaths += job.keepAlive.pathStates.map { ("PathState", $0.path) }

    for (key, path) in absolutePaths where !path.isEmpty {
      if !path.hasPrefix("/") {
        add("path.absolute", .error, "\(key) must be an absolute path: \(path)", .launchdPlist, "\(key)-\(path)")
      }
      if isPrivacyProtected(path) {
        add("path.privacy", .warning,
            "\(path) is protected by macOS privacy controls. The job may be blocked from using it.",
            .launchdPlist, "\(key)-\(path)")
      }
    }

    if job.context == .daemon {
      for path in [job.standardOutPath, job.standardErrorPath] where isUserWritableLocation(path) {
        add("log.user-writable", .warning,
            "\(path) is in a user-writable folder. A root daemon writing there can be abused with symlinks.",
            .security, path)
      }
    }
  }

  /// Daemon logs grow without limit unless something trims them. newsyslog can rotate the logs of jobs that start
  /// and exit; a job that keeps running holds its files open, so it should log to the unified log instead.
  private static func logRotationIssues(
    _ job: LaunchJob,
    in project: Project,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    guard job.context == .daemon, project.settings.mode == .package else { return }
    let logPaths = [job.standardOutPath, job.standardErrorPath].filter { !$0.isEmpty }
    guard !logPaths.isEmpty else { return }
    if !LogRotation.canRotateLogs(job) {
      let message =
        "This job keeps running, and launchd keeps its log file open, so the file grows until the job restarts "
        + "and can’t be rotated safely. For long-running jobs, log to the unified log instead (for example "
        + "with logger or os_log) and leave Standard Output empty."
      add("log.keepalive-file", .warning, message, .launchdPlist, "")
    } else if project.settings.rotateLogs {
      for path in logPaths where path.hasPrefix("/") && !LogRotation.isRotatable(path) {
        let message = "\(path) contains a space or #, which newsyslog can’t read, so it is not rotated."
        add("log.rotation-path", .warning, message, .packaging, path)
      }
    } else if job.startInterval != nil || !job.calendarIntervals.isEmpty {
      let message =
        "This job runs repeatedly and adds to its log each time, so the log grows without limit. Turn on "
        + "Options ▸ Logging ▸ Rotate Logs."
      add("log.rotation", .warning, message, .packaging, "")
    }
  }

  /// In a DDM background task the Mac stops and restarts the job itself when the configuration changes. launchd
  /// relaunching a KeepAlive job during that update has been seen to fail re-registration with "Operation already in
  /// progress" (SupportCompanion wiki, "Deploying the helper"), so Run at Load is the safer start.
  private static func backgroundTaskIssues(
    _ job: LaunchJob,
    in project: Project,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    guard project.settings.mode == .declarative, job.context != .userAgent, job.keepAlive.mode != .off else { return }
    let message =
      "Keep Alive can make a DDM background task fail to re-register when its configuration updates. The Mac "
      + "restarts the task itself on updates; use Run at Load instead of Keep Alive."
    add("ddm.keepalive", .warning, message, .backgroundTasks, "")
  }

  private static func secretIssues(
    _ job: LaunchJob,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    let severity: IssueSeverity = job.context == .userAgent ? .warning : .error
    for variable in job.environment where looksSecret(variable.name) {
      add("secret.environment", severity,
          "\(variable.name) looks like a secret. launchd plists are readable by every user on the Mac.",
          .security, variable.name)
    }
    for (index, argument) in job.argumentValues.enumerated() where looksSecret(argument) {
      add("secret.argument", .warning,
          "Argument \(index + 1) may contain a secret. Arguments are visible in the plist and in process listings.",
          .security, String(index))
    }
  }

  private static func additionalKeyIssues(
    _ job: LaunchJob,
    add: (String, IssueSeverity, String, IssueSource, String) -> Void
  ) {
    let obsolete: [String: String] = [
      "OnDemand": "OnDemand is obsolete. Use KeepAlive instead.",
      "ServiceIPC": "ServiceIPC is obsolete. Remove it.",
      "HopefullyExitsFirst": "HopefullyExitsFirst is no longer implemented.",
      "HopefullyExitsLast": "HopefullyExitsLast is no longer implemented.",
      "TimeOut": "TimeOut is no longer implemented.",
      "LimitLoadToHosts": "LimitLoadToHosts is no longer supported.",
      "LimitLoadFromHosts": "LimitLoadFromHosts is no longer supported."
    ]
    for key in job.additionalKeys.keys.sorted() {
      if let message = obsolete[key] {
        add("key.obsolete", .warning, message, .launchdPlist, key)
      }
    }
    if job.additionalKeys["BundleProgram"] != nil {
      add("key.bundle-program", .error,
          "BundleProgram only works for plists installed with SMAppService, not deployed plists.",
          .launchdPlist, "")
    }
    if job.additionalKeys["WaitForDebugger"] != nil {
      add("key.wait-for-debugger", .warning,
          "WaitForDebugger launches the job suspended. Remove it before deployment.", .launchdPlist, "")
    }
    if job.additionalKeys["RootDirectory"] != nil {
      add("key.root-directory", .warning,
          "Apple strongly discourages RootDirectory because system IPC may fail inside the jail.",
          .launchdPlist, "")
    }
    if job.additionalKeys["EnvironmentVariables"] != nil {
      add("key.environment-types", .warning,
          "EnvironmentVariables contains values that are not strings. launchd ignores them.",
          .launchdPlist, "")
    }
  }

  // MARK: - Helpers

  /// Folders macOS owns and protects, so programs there are safe for root jobs.
  static func isSystemLocation(_ path: String) -> Bool {
    ["/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/"].contains {
      path.hasPrefix($0)
    }
  }

  static func isUserWritableLocation(_ path: String) -> Bool {
    let prefixes = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/", "/Users/Shared/", "~"]
    return prefixes.contains { path.hasPrefix($0) }
  }

  static func isPrivacyProtected(_ path: String) -> Bool {
    let markers = ["/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents", "/Pictures", "/Movies", "/Music"]
    return (path.hasPrefix("/Users/") || path.hasPrefix("~/"))
      && markers.contains { path.contains($0) }
  }

  static func looksSecret(_ text: String) -> Bool {
    text.lowercased().contains(/pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential/)
  }
}
