import Foundation
import Testing

@testable import LaunchdOps

struct CronConverterTests {
  private struct Fields: Equatable {
    var minute, hour, day, weekday, month: Int?
  }

  private func fields(_ expression: String) throws -> [Fields] {
    guard case .calendar(let intervals) = try CronConverter.schedule(from: expression) else {
      Issue.record("Expected a calendar schedule for \(expression)")
      return []
    }
    return intervals.map {
      Fields(minute: $0.minute, hour: $0.hour, day: $0.day, weekday: $0.weekday, month: $0.month)
    }
  }

  private func error(_ expression: String) -> CronConverter.ConversionError? {
    do {
      _ = try CronConverter.schedule(from: expression)
      return nil
    } catch {
      return error
    }
  }

  // MARK: - Schedules

  @Test func weekdayRangeExpandsToOneEntryPerDay() throws {
    let result = try fields("0 9 * * 1-5")
    #expect(result == (1...5).map { Fields(minute: 0, hour: 9, weekday: $0) })
  }

  @Test func restrictedDayAndWeekdayBecomeSeparateEntries() throws {
    // crontab(5) example: 4:30 on the 1st and 15th, plus every Friday.
    let result = try fields("30 4 1,15 * 5")
    #expect(
      result == [
        Fields(minute: 30, hour: 4, day: 1),
        Fields(minute: 30, hour: 4, day: 15),
        Fields(minute: 30, hour: 4, weekday: 5),
      ])
  }

  @Test func fullDayRangeWithWeekdayMeansEveryDay() throws {
    #expect(try fields("0 6 1-31 * 1") == [Fields(minute: 0, hour: 6)])
  }

  @Test func stepsListsAndNames() throws {
    #expect(try fields("*/15 8 * * *").map(\.minute) == [0, 15, 30, 45])
    #expect(try fields("0 8-12/2 * * *").map(\.hour) == [8, 10, 12])
    #expect(try fields("0 0 1 jan *") == [Fields(minute: 0, hour: 0, day: 1, month: 1)])
    #expect(try fields("0 0 * * SUN") == [Fields(minute: 0, hour: 0, weekday: 0)])
  }

  @Test func sundayAsSevenBecomesZero() throws {
    #expect(try fields("0 0 * * 7") == [Fields(minute: 0, hour: 0, weekday: 0)])
    #expect(try fields("0 0 * * 0-7") == [Fields(minute: 0, hour: 0)])
  }

  @Test func everyMinuteIsOneEmptyInterval() throws {
    #expect(try fields("* * * * *") == [Fields()])
  }

  @Test func outputOrderIsDeterministic() throws {
    #expect(
      try fields("5,1 3,2 * * *") == [
        Fields(minute: 1, hour: 2), Fields(minute: 5, hour: 2),
        Fields(minute: 1, hour: 3), Fields(minute: 5, hour: 3),
      ])
  }

  @Test func specialStrings() throws {
    #expect(try fields("@daily") == [Fields(minute: 0, hour: 0)])
    #expect(try fields("@weekly") == [Fields(minute: 0, hour: 0, weekday: 0)])
    #expect(try fields("@yearly") == [Fields(minute: 0, hour: 0, day: 1, month: 1)])
    #expect(try CronConverter.schedule(from: "@reboot") == .atLoad)
    #expect(error("@sometimes") == .unknownSpecial("@sometimes"))
  }

  @Test func rejectsInvalidExpressions() {
    #expect(error("0 9 * *") == .fieldCount(4))
    #expect(error("60 * * * *") == .outOfRange(field: "minute", value: 60, range: 0...59))
    #expect(error("0 0 0 * *") == .outOfRange(field: "day", value: 0, range: 1...31))
    #expect(error("*/0 * * * *") == .invalidValue(field: "minute", value: "*/0"))
    #expect(error("0 0 * jan-mar *") == .invalidValue(field: "month", value: "jan-mar"))
    #expect(error("0 0 * * mon,tue") == .invalidValue(field: "weekday", value: "mon,tue"))
    #expect(error("0 5-1 * * *") == .invalidValue(field: "hour", value: "5-1"))
  }

  @Test func rejectsDayAndWeekdayThatMustBothMatch() {
    #expect(error("0 0 */2 * 1") == .dayAndWeekdayMustBothMatch)
    #expect(error("0 0 1 * */2") == .dayAndWeekdayMustBothMatch)
  }

  @Test func rejectsExpansionsBeyondTheLimit() throws {
    // 12 minutes × 9 hours × 5 weekdays.
    #expect(error("*/5 9-17 * * 1-5") == .tooManyIntervals(540))
    #expect(try fields("*/5 * * * *").count == 12)
  }

  @Test func rejectsSignedNumbers() {
    #expect(error("+5 * * * *") == .invalidValue(field: "minute", value: "+5"))
  }
}
