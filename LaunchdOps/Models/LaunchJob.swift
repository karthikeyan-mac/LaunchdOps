import Foundation

enum JobContext: String, Codable, CaseIterable, Identifiable, Sendable {
  case daemon
  case globalAgent
  case userAgent

  var id: String { rawValue }

  var title: String {
    switch self {
    case .daemon: "Launch Daemon"
    case .globalAgent: "Launch Agent"
    case .userAgent: "User Launch Agent"
    }
  }

  var systemImage: String {
    switch self {
    case .daemon: "gearshape.2"
    case .globalAgent: "person.2"
    case .userAgent: "person"
    }
  }

  var installDirectory: String {
    switch self {
    case .daemon: "/Library/LaunchDaemons"
    case .globalAgent: "/Library/LaunchAgents"
    case .userAgent: "~/Library/LaunchAgents"
    }
  }

  var isAgent: Bool { self != .daemon }

  static func inferred(fromPath path: String) -> JobContext {
    if path.contains("/LaunchDaemons/") { return .daemon }
    if path.hasPrefix("/Library/LaunchAgents/") || path.contains("BackgroundTaskServices/LaunchAgents/") {
      return .globalAgent
    }
    if path.contains("/Library/LaunchAgents/") { return .userAgent }
    return .daemon
  }
}

struct TextItem: Identifiable, Hashable, Sendable {
  var id = UUID()
  var value: String
}

struct EnvironmentVariable: Identifiable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var value: String

  struct Assignment: Equatable, Sendable {
    var name: String
    var value: String
  }

  /// Updates variables whose names match and appends the rest, keeping the existing order.
  static func merge(_ assignments: [Assignment], into variables: inout [EnvironmentVariable]) {
    for assignment in assignments {
      if let index = variables.firstIndex(where: { $0.name == assignment.name }) {
        variables[index].value = assignment.value
      } else {
        variables.append(EnvironmentVariable(name: assignment.name, value: assignment.value))
      }
    }
  }

  struct ParsedText: Equatable, Sendable {
    var assignments: [Assignment] = []
    var invalidLines: [Int] = []
  }

  static func isValidName(_ name: String) -> Bool {
    name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
  }

  /// Parses `NAME=value` lines. Blank lines and `#` comments are skipped, a leading `export ` is allowed,
  /// and one pair of matching quotes around the value is removed. Later lines win for repeated names.
  static func parse(_ text: String) -> ParsedText {
    var result = ParsedText()
    for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("export ") {
        line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
      }
      guard let equals = line.firstIndex(of: "="), isValidName(String(line[..<equals])) else {
        result.invalidLines.append(index + 1)
        continue
      }
      let name = String(line[..<equals])
      var value = String(line[line.index(after: equals)...])
      if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
        value = String(value.dropFirst().dropLast())
      }
      result.assignments.removeAll { $0.name == name }
      result.assignments.append(Assignment(name: name, value: value))
    }
    return result
  }
}

struct CalendarInterval: Identifiable, Hashable, Sendable {
  var id = UUID()
  var minute: Int?
  var hour: Int?
  var day: Int?
  var weekday: Int?
  var month: Int?

  var isEmpty: Bool {
    minute == nil && hour == nil && day == nil && weekday == nil && month == nil
  }

  var summary: String {
    let time: String
    switch (hour, minute) {
    case let (hour?, minute?):
      time = String(format: "at %02d:%02d", hour, minute)
    case let (hour?, nil):
      time = "every minute of hour \(hour)"
    case let (nil, minute?):
      time = "at minute \(minute) of every hour"
    case (nil, nil):
      time = "every minute"
    }

    var days: [String] = []
    if let weekday, (0...7).contains(weekday) {
      days.append("on \(Calendar.current.weekdaySymbols[weekday % 7])s")
    }
    if let day {
      days.append("on day \(day)")
    }
    let dayText = days.isEmpty ? "every day" : days.joined(separator: " or ")
    let monthText = month.flatMap { (1...12).contains($0) ? " in \(Calendar.current.monthSymbols[$0 - 1])" : nil } ?? ""
    return "Runs \(dayText)\(monthText) \(time)."
  }
}

struct PathStateCondition: Identifiable, Hashable, Sendable {
  var id = UUID()
  var path: String
  var keepAliveWhenExists: Bool
}

enum KeepAliveMode: String, CaseIterable, Identifiable, Sendable {
  case off
  case always
  case conditional

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: "Off"
    case .always: "Always"
    case .conditional: "When Conditions Match"
    }
  }
}

struct KeepAlive: Hashable, Sendable {
  var mode: KeepAliveMode = .off
  var successfulExit: Bool?
  var crashed: Bool?
  var pathStates: [PathStateCondition] = []
  var otherKeys: [String: PlistValue] = [:]

  var hasConditions: Bool {
    successfulExit != nil || crashed != nil || !pathStates.isEmpty || !otherKeys.isEmpty
  }

  /// Conditional keep-alive whose only condition is `Crashed = true`.
  var isCrashOnly: Bool {
    mode == .conditional && crashed == true && successfulExit == nil && pathStates.isEmpty && otherKeys.isEmpty
  }
}

enum ProcessTypeOption: String, CaseIterable, Identifiable, Sendable {
  case background = "Background"
  case standard = "Standard"
  case adaptive = "Adaptive"
  case interactive = "Interactive"

  var id: String { rawValue }

  var help: String {
    switch self {
    case .background: "Strict CPU and I/O limits for work the user did not ask for, so it doesn’t get in the way."
    case .standard: "Light CPU and I/O limits. The same as leaving Process Type unset."
    case .adaptive: "Moves between Background and Interactive limits depending on XPC activity."
    case .interactive: "No limits, like an app. Use only when an app’s responsiveness depends on this job."
    }
  }

  /// Every value with its description, for the Process Type info popover.
  static var summary: String {
    (["Default: the same as Standard."] + allCases.map { "\($0.rawValue): \($0.help)" }).joined(separator: "\n")
  }
}

enum SessionType: String, CaseIterable, Identifiable, Sendable {
  case aqua = "Aqua"
  case background = "Background"
  case loginWindow = "LoginWindow"
  case standardIO = "StandardIO"

  var id: String { rawValue }

  /// Display name; the plist keeps `rawValue`.
  var title: String {
    switch self {
    case .aqua: "Aqua (Logged-In Desktop)"
    case .background: "Background (No GUI Login)"
    case .loginWindow: "LoginWindow (Login Screen)"
    case .standardIO: "StandardIO (Command Line)"
    }
  }

  var help: String {
    switch self {
    case .aqua: "Loads when the user logs in at the desktop. This is the default."
    case .background: "Loads in the user’s background session, even without a desktop login."
    case .loginWindow: "Loads while the login window is showing. The agent runs as root."
    case .standardIO: "Loads in command-line sessions. Rarely needed."
    }
  }
}

struct LaunchJob: Identifiable, Hashable, Sendable {
  var id = UUID()
  var context: JobContext
  var label: String
  var disabled = false
  var program = ""
  var arguments: [TextItem] = []
  var workingDirectory = ""
  var environment: [EnvironmentVariable] = []
  var umask = ""
  var userName = ""
  var groupName = ""
  var initGroups: Bool?
  var runAtLoad = false
  var startInterval: Int?
  var calendarIntervals: [CalendarInterval] = []
  var watchPaths: [TextItem] = []
  var queueDirectories: [TextItem] = []
  var startOnMount = false
  var keepAlive = KeepAlive()
  var throttleInterval: Int?
  var exitTimeOut: Int?
  var launchOnlyOnce = false
  var abandonProcessGroup = false
  var standardOutPath = ""
  var standardErrorPath = ""
  var sessionTypes: [String] = []
  var processType: ProcessTypeOption?
  var nice: Int?
  var lowPriorityIO = false
  var lowPriorityBackgroundIO = false
  var associatedBundleIdentifiers: [TextItem] = []
  var additionalKeys: [String: PlistValue] = [:]

  init(context: JobContext, label: String) {
    self.context = context
    self.label = label
  }

  /// The arguments launchd receives: empty rows (added and never filled in) are left out of the plist.
  var argumentValues: [String] {
    arguments.map(\.value).filter { !$0.isEmpty }
  }

  var executablePath: String {
    program.isEmpty ? (argumentValues.first ?? "") : program
  }

  var displayName: String {
    label.isEmpty ? "Untitled Job" : label
  }

  var fileName: String {
    "\(label.isEmpty ? id.uuidString : label).plist"
  }

  var installPath: String {
    "\(context.installDirectory)/\(fileName)"
  }
}

extension LaunchJob {
  /// Arguments after Add Argument. With Program set, ProgramArguments[0] is only the process name, so the first
  /// Add puts the program path there and adds an empty row for the first real option. Otherwise it adds one row.
  static func addingArgument(to arguments: [TextItem], program: String) -> [TextItem] {
    let path = program.trimmingCharacters(in: .whitespacesAndNewlines)
    if arguments.isEmpty && !path.isEmpty {
      return [TextItem(value: path), TextItem(value: "")]
    }
    return arguments + [TextItem(value: "")]
  }
}

extension LaunchJob {
  /// Settings ▸ General ▸ Log Folder, cleaned up; nil when it is not an absolute, root-owned location.
  static func logFolder(from setting: String) -> String? {
    var folder = setting.trimmingCharacters(in: .whitespacesAndNewlines)
    while folder.count > 1 && folder.hasSuffix("/") {
      folder.removeLast()
    }
    guard folder != "/", SafeInstallPath.problem(withFolder: folder) == nil,
      !Validator.isUserWritableLocation(folder + "/")
    else { return nil }
    return folder
  }

  /// Points a new daemon's output and errors at `<folder>/<label>.log` and `<folder>/<label>.error.log`.
  /// Agents run as the user and cannot write to a root-owned folder, so they are left alone.
  mutating func useLogFolder(_ setting: String) {
    guard context == .daemon, !label.isEmpty, let folder = Self.logFolder(from: setting) else { return }
    standardOutPath = "\(folder)/\(label).log"
    standardErrorPath = "\(folder)/\(label).error.log"
  }
}
