import Foundation

extension LaunchJob {
  init(dictionary: [String: PlistValue], context: JobContext) {
    var reader = PlistReader(values: dictionary)
    self.init(context: context, label: reader.string("Label") ?? "")

    disabled = reader.bool("Disabled") ?? false
    program = reader.string("Program") ?? ""
    arguments = (reader.stringArray("ProgramArguments") ?? []).map { TextItem(value: $0) }
    workingDirectory = reader.string("WorkingDirectory") ?? ""
    if let variables = reader.stringDictionary("EnvironmentVariables") {
      environment = variables.keys.sorted().map { EnvironmentVariable(name: $0, value: variables[$0] ?? "") }
    }
    if let value = reader.int("Umask") {
      umask = "0" + String(value, radix: 8)
    } else if let value = reader.string("Umask") {
      umask = value
    }
    userName = reader.string("UserName") ?? ""
    groupName = reader.string("GroupName") ?? ""
    initGroups = reader.bool("InitGroups")

    runAtLoad = reader.bool("RunAtLoad") ?? false
    startInterval = reader.int("StartInterval")
    calendarIntervals = reader.calendarIntervals("StartCalendarInterval") ?? []
    watchPaths = (reader.stringArray("WatchPaths") ?? []).map { TextItem(value: $0) }
    queueDirectories = (reader.stringArray("QueueDirectories") ?? []).map { TextItem(value: $0) }
    startOnMount = reader.bool("StartOnMount") ?? false
    keepAlive = reader.keepAlive() ?? KeepAlive()

    throttleInterval = reader.int("ThrottleInterval")
    exitTimeOut = reader.int("ExitTimeOut")
    launchOnlyOnce = reader.bool("LaunchOnlyOnce") ?? false
    abandonProcessGroup = reader.bool("AbandonProcessGroup") ?? false

    standardOutPath = reader.string("StandardOutPath") ?? ""
    standardErrorPath = reader.string("StandardErrorPath") ?? ""

    sessionTypes = reader.stringOrStringArray("LimitLoadToSessionType") ?? []
    processType = reader.processType()
    nice = reader.int("Nice")
    lowPriorityIO = reader.bool("LowPriorityIO") ?? false
    lowPriorityBackgroundIO = reader.bool("LowPriorityBackgroundIO") ?? false
    associatedBundleIdentifiers = (reader.stringOrStringArray("AssociatedBundleIdentifiers") ?? [])
      .map { TextItem(value: $0) }

    additionalKeys = reader.values
  }

  var plistDictionary: [String: PlistValue] {
    var output = additionalKeys

    output["Label"] = .string(label)
    output.setTrue("Disabled", disabled)
    output.setString("Program", program)
    if !argumentValues.isEmpty {
      output["ProgramArguments"] = .array(argumentValues.map(PlistValue.string))
    }
    output.setString("WorkingDirectory", workingDirectory)
    if !environment.isEmpty {
      var variables: [String: PlistValue] = [:]
      for variable in environment where !variable.name.isEmpty {
        variables[variable.name] = .string(variable.value)
      }
      output["EnvironmentVariables"] = .dictionary(variables)
    }
    if let value = Int(umask.trimmingCharacters(in: .whitespaces), radix: 8) {
      // launchd reads integer Umask values as decimal, so the octal entry is converted here.
      output["Umask"] = .integer(value)
    }
    output.setString("UserName", userName)
    output.setString("GroupName", groupName)
    if let initGroups {
      output["InitGroups"] = .bool(initGroups)
    }

    output.setTrue("RunAtLoad", runAtLoad)
    output.setInt("StartInterval", startInterval)
    let intervals = calendarIntervals.map(\.plistValue)
    if intervals.count == 1, let first = intervals.first {
      output["StartCalendarInterval"] = first
    } else if intervals.count > 1 {
      output["StartCalendarInterval"] = .array(intervals)
    }
    output.setStringArray("WatchPaths", watchPaths.map(\.value))
    output.setStringArray("QueueDirectories", queueDirectories.map(\.value))
    output.setTrue("StartOnMount", startOnMount)
    if let keepAliveValue = keepAlive.plistValue {
      output["KeepAlive"] = keepAliveValue
    }

    output.setInt("ThrottleInterval", throttleInterval)
    output.setInt("ExitTimeOut", exitTimeOut)
    output.setTrue("LaunchOnlyOnce", launchOnlyOnce)
    output.setTrue("AbandonProcessGroup", abandonProcessGroup)

    output.setString("StandardOutPath", standardOutPath)
    output.setString("StandardErrorPath", standardErrorPath)

    if sessionTypes.count == 1, let only = sessionTypes.first {
      output["LimitLoadToSessionType"] = .string(only)
    } else {
      output.setStringArray("LimitLoadToSessionType", sessionTypes)
    }
    if let processType {
      output["ProcessType"] = .string(processType.rawValue)
    }
    output.setInt("Nice", nice)
    output.setTrue("LowPriorityIO", lowPriorityIO)
    output.setTrue("LowPriorityBackgroundIO", lowPriorityBackgroundIO)
    output.setStringArray("AssociatedBundleIdentifiers", associatedBundleIdentifiers.map(\.value))

    return output
  }

  func renderedPlist() throws -> Data {
    try PropertyListCoding.xmlData(from: plistDictionary)
  }

  func renderedPlistXML() throws -> String {
    String(decoding: try renderedPlist(), as: UTF8.self)
  }
}

private extension CalendarInterval {
  var plistValue: PlistValue {
    var values: [String: PlistValue] = [:]
    if let minute { values["Minute"] = .integer(minute) }
    if let hour { values["Hour"] = .integer(hour) }
    if let day { values["Day"] = .integer(day) }
    if let weekday { values["Weekday"] = .integer(weekday) }
    if let month { values["Month"] = .integer(month) }
    return .dictionary(values)
  }

  init?(dictionary: [String: PlistValue]) {
    let known: Set = ["Minute", "Hour", "Day", "Weekday", "Month"]
    guard Set(dictionary.keys).isSubset(of: known), dictionary.values.allSatisfy({ $0.intValue != nil }) else {
      return nil
    }
    self.init(
      minute: dictionary["Minute"]?.intValue,
      hour: dictionary["Hour"]?.intValue,
      day: dictionary["Day"]?.intValue,
      weekday: dictionary["Weekday"]?.intValue,
      month: dictionary["Month"]?.intValue
    )
  }
}

private extension KeepAlive {
  var plistValue: PlistValue? {
    switch mode {
    case .off:
      return nil
    case .always:
      return .bool(true)
    case .conditional:
      var values = otherKeys
      if let successfulExit { values["SuccessfulExit"] = .bool(successfulExit) }
      if let crashed { values["Crashed"] = .bool(crashed) }
      let paths = pathStates.filter { !$0.path.isEmpty }
      if !paths.isEmpty {
        var states: [String: PlistValue] = [:]
        for state in paths {
          states[state.path] = .bool(state.keepAliveWhenExists)
        }
        values["PathState"] = .dictionary(states)
      }
      return .dictionary(values)
    }
  }
}

private struct PlistReader {
  var values: [String: PlistValue]

  mutating func take<T>(_ key: String, _ transform: (PlistValue) -> T?) -> T? {
    guard let value = values[key], let result = transform(value) else { return nil }
    values[key] = nil
    return result
  }

  mutating func string(_ key: String) -> String? { take(key) { $0.stringValue } }
  mutating func int(_ key: String) -> Int? { take(key) { $0.intValue } }
  mutating func bool(_ key: String) -> Bool? { take(key) { $0.boolValue } }
  mutating func stringArray(_ key: String) -> [String]? { take(key) { $0.stringArrayValue } }

  mutating func stringOrStringArray(_ key: String) -> [String]? {
    take(key) { value in
      if let string = value.stringValue { return [string] }
      return value.stringArrayValue
    }
  }

  mutating func stringDictionary(_ key: String) -> [String: String]? {
    take(key) { value in
      guard let dictionary = value.dictionaryValue else { return nil }
      let strings = dictionary.compactMapValues(\.stringValue)
      return strings.count == dictionary.count ? strings : nil
    }
  }

  mutating func calendarIntervals(_ key: String) -> [CalendarInterval]? {
    take(key) { value in
      if let dictionary = value.dictionaryValue {
        return CalendarInterval(dictionary: dictionary).map { [$0] }
      }
      guard let array = value.arrayValue else { return nil }
      let intervals = array.compactMap { $0.dictionaryValue.flatMap(CalendarInterval.init(dictionary:)) }
      return intervals.count == array.count ? intervals : nil
    }
  }

  mutating func processType() -> ProcessTypeOption? {
    take("ProcessType") { $0.stringValue.flatMap(ProcessTypeOption.init(rawValue:)) }
  }

  mutating func keepAlive() -> KeepAlive? {
    take("KeepAlive") { value in
      if let flag = value.boolValue {
        return KeepAlive(mode: flag ? .always : .off)
      }
      guard var dictionary = value.dictionaryValue else { return nil }
      var result = KeepAlive(mode: .conditional)
      if let flag = dictionary["SuccessfulExit"]?.boolValue {
        result.successfulExit = flag
        dictionary["SuccessfulExit"] = nil
      }
      if let flag = dictionary["Crashed"]?.boolValue {
        result.crashed = flag
        dictionary["Crashed"] = nil
      }
      let states = dictionary["PathState"]?.dictionaryValue ?? [:]
      if !states.isEmpty, states.values.allSatisfy({ $0.boolValue != nil }) {
        result.pathStates = states.keys.sorted().map {
          PathStateCondition(path: $0, keepAliveWhenExists: states[$0]?.boolValue ?? true)
        }
        dictionary["PathState"] = nil
      }
      result.otherKeys = dictionary
      return result
    }
  }
}

private extension Dictionary where Key == String, Value == PlistValue {
  mutating func setString(_ key: String, _ value: String) {
    if !value.isEmpty { self[key] = .string(value) }
  }

  mutating func setInt(_ key: String, _ value: Int?) {
    if let value { self[key] = .integer(value) }
  }

  mutating func setTrue(_ key: String, _ value: Bool) {
    if value { self[key] = .bool(true) }
  }

  mutating func setStringArray(_ key: String, _ values: [String]) {
    let filtered = values.filter { !$0.isEmpty }
    if !filtered.isEmpty { self[key] = .array(filtered.map(PlistValue.string)) }
  }
}
