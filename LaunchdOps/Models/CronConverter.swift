import Foundation

/// Converts crontab(5) schedules into launchd calendar intervals.
enum CronConverter {
  /// Upper bound on generated `StartCalendarInterval` entries per schedule. launchd documents no limit;
  /// beyond this a Start Interval is almost always the better fit.
  static let maximumIntervals = 100

  enum Schedule: Hashable, Sendable {
    case calendar([CalendarInterval])
    case atLoad
  }

  enum ConversionError: LocalizedError, Hashable, Sendable {
    case fieldCount(Int)
    case invalidValue(field: String, value: String)
    case outOfRange(field: String, value: Int, range: ClosedRange<Int>)
    case dayAndWeekdayMustBothMatch
    case tooManyIntervals(Int)
    case unknownSpecial(String)

    var errorDescription: String? {
      switch self {
      case .fieldCount(let count):
        "Expected 5 time fields (minute, hour, day, month, weekday) but found \(count)."
      case .invalidValue(let field, let value):
        "“\(value)” is not a valid \(field) value."
      case .outOfRange(let field, let value, let range):
        "\(value) is outside the \(field) range \(range.lowerBound)–\(range.upperBound)."
      case .dayAndWeekdayMustBothMatch:
        "Day and weekday are both limited and one starts with *, so cron requires both. launchd cannot; convert this schedule manually."
      case .tooManyIntervals(let count):
        "This expands to \(count) schedules. Use Start Interval instead."
      case .unknownSpecial(let text):
        "“\(text)” is not a supported special string."
      }
    }
  }

  // MARK: - Schedules

  private struct Field {
    let name: String
    let range: ClosedRange<Int>
    var names: [String] = []
    var nameOffset = 0
  }

  private static let minuteField = Field(name: "minute", range: 0...59)
  private static let hourField = Field(name: "hour", range: 0...23)
  private static let dayField = Field(name: "day", range: 1...31)
  private static let monthField = Field(
    name: "month", range: 1...12,
    names: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], nameOffset: 1
  )
  private static let weekdayField = Field(
    name: "weekday", range: 0...7, names: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
  )

  private static let specialStrings: [String: String] = [
    "@yearly": "0 0 1 1 *",
    "@annually": "0 0 1 1 *",
    "@monthly": "0 0 1 * *",
    "@weekly": "0 0 * * 0",
    "@daily": "0 0 * * *",
    "@midnight": "0 0 * * *",
    "@hourly": "0 * * * *",
  ]

  /// Converts five cron time fields, or a special string such as `@daily`, into a schedule.
  static func schedule(from expression: String) throws(ConversionError) -> Schedule {
    let trimmed = expression.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("@") {
      let special = trimmed.lowercased()
      if special == "@reboot" { return .atLoad }
      guard let expanded = specialStrings[special] else { throw .unknownSpecial(trimmed) }
      return try schedule(from: expanded)
    }
    let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    guard fields.count == 5 else { throw .fieldCount(fields.count) }
    return .calendar(try intervals(fields))
  }

  private static func intervals(_ fields: [String]) throws(ConversionError) -> [CalendarInterval] {
    let minutes = try values(fields[0], minuteField)
    let hours = try values(fields[1], hourField)
    let days = try values(fields[2], dayField)
    let months = try values(fields[3], monthField)
    let weekdays = try values(fields[4], weekdayField)

    // cron runs when either day field matches if both are restricted, and requires both when
    // one of them starts with *. launchd's Day + Weekday means "either", so only the first maps.
    var dayEntries: [(day: Int?, weekday: Int?)]
    let dayIsStar = fields[2].hasPrefix("*")
    let weekdayIsStar = fields[4].hasPrefix("*")
    if !dayIsStar && !weekdayIsStar {
      if let days, let weekdays {
        dayEntries = days.map { ($0, nil) } + weekdays.map { (nil, $0) }
      } else {
        dayEntries = [(nil, nil)]
      }
    } else {
      if days != nil && weekdays != nil { throw .dayAndWeekdayMustBothMatch }
      dayEntries = days.map { $0.map { ($0, nil) } } ?? weekdays.map { $0.map { (nil, $0) } } ?? [(nil, nil)]
    }

    let minuteOptions: [Int?] = minutes ?? [nil]
    let hourOptions: [Int?] = hours ?? [nil]
    let monthOptions: [Int?] = months ?? [nil]
    let count = minuteOptions.count * hourOptions.count * monthOptions.count * dayEntries.count
    guard count <= maximumIntervals else { throw .tooManyIntervals(count) }

    var result: [CalendarInterval] = []
    for month in monthOptions {
      for entry in dayEntries {
        for hour in hourOptions {
          for minute in minuteOptions {
            result.append(
              CalendarInterval(minute: minute, hour: hour, day: entry.day, weekday: entry.weekday, month: month)
            )
          }
        }
      }
    }
    return result
  }

  /// Returns the sorted values a field allows, or `nil` when it allows every value.
  private static func values(_ text: String, _ field: Field) throws(ConversionError) -> [Int]? {
    var result = Set<Int>()
    for part in text.split(separator: ",", omittingEmptySubsequences: false) {
      let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
      guard !part.isEmpty, pieces.count <= 2 else { throw .invalidValue(field: field.name, value: text) }

      var step = 1
      if pieces.count == 2 {
        guard let parsed = number(pieces[1]), parsed > 0 else { throw .invalidValue(field: field.name, value: text) }
        step = parsed
      }

      let base = String(pieces[0])
      let lower: Int
      let upper: Int
      if base == "*" {
        lower = field.range.lowerBound
        upper = field.range.upperBound
      } else if base.contains("-") {
        let bounds = base.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = number(bounds[0]), let last = number(bounds[1]), first <= last else {
          throw .invalidValue(field: field.name, value: text)
        }
        lower = first
        upper = last
      } else {
        // crontab(5): names are allowed only on their own, not in ranges, lists or steps.
        let allowsName = pieces.count == 1 && part.count == text.count
        guard let single = number(base) ?? (allowsName ? nameValue(base, field) : nil), pieces.count == 1 else {
          throw .invalidValue(field: field.name, value: text)
        }
        lower = single
        upper = single
      }

      for value in [lower, upper] where !field.range.contains(value) {
        throw .outOfRange(field: field.name, value: value, range: field.range)
      }
      for value in stride(from: lower, through: upper, by: step) {
        result.insert(field.name == weekdayField.name && value == 7 ? 0 : value)
      }
    }

    let everyValue = field.name == weekdayField.name ? Set(0...6) : Set(field.range)
    return result == everyValue ? nil : result.sorted()
  }

  /// Digits only; `Int("+5")` would otherwise accept a sign cron does not allow.
  private static func number<S: StringProtocol>(_ text: S) -> Int? {
    guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
    return Int(text)
  }

  private static func nameValue(_ text: String, _ field: Field) -> Int? {
    field.names.firstIndex(of: text.lowercased()).map { $0 + field.nameOffset }
  }
}

extension CronConverter.Schedule {
  var summary: String {
    switch self {
    case .atLoad:
      return "Runs at load (@reboot)."
    case .calendar(let intervals):
      let shown = intervals.prefix(3).map(\.summary).joined(separator: " ")
      let more = intervals.count > 3 ? " And \(intervals.count - 3) more." : ""
      return intervals.count == 1 ? shown : "\(intervals.count) schedules. \(shown)\(more)"
    }
  }
}
