import Foundation

enum PlistValue: Hashable, Sendable {
  case string(String)
  case integer(Int)
  case real(Double)
  case bool(Bool)
  case date(Date)
  case data(Data)
  case array([PlistValue])
  case dictionary([String: PlistValue])

  init?(_ value: Any) {
    switch value {
    case let string as String:
      self = .string(string)
    case let number as NSNumber:
      // NSNumber bridges booleans and numbers alike; CFBoolean identity is the only reliable check.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else if CFNumberIsFloatType(number) {
        self = .real(number.doubleValue)
      } else {
        self = .integer(number.intValue)
      }
    case let date as Date:
      self = .date(date)
    case let data as Data:
      self = .data(data)
    case let array as [Any]:
      self = .array(array.compactMap(PlistValue.init))
    case let dictionary as [String: Any]:
      self = .dictionary(dictionary.compactMapValues(PlistValue.init))
    default:
      return nil
    }
  }

  var foundationValue: Any {
    switch self {
    case .string(let value): return value
    case .integer(let value): return value
    case .real(let value): return value
    case .bool(let value): return value
    case .date(let value): return value
    case .data(let value): return value
    case .array(let values): return values.map(\.foundationValue)
    case .dictionary(let values): return values.mapValues(\.foundationValue)
    }
  }

  var typeName: String {
    switch self {
    case .string: "String"
    case .integer: "Integer"
    case .real: "Real"
    case .bool: "Boolean"
    case .date: "Date"
    case .data: "Data"
    case .array: "Array"
    case .dictionary: "Dictionary"
    }
  }

  var summary: String {
    switch self {
    case .string(let value): value
    case .integer(let value): String(value)
    case .real(let value): String(value)
    case .bool(let value): value ? "true" : "false"
    case .date(let value): value.formatted(.iso8601)
    case .data(let value): "\(value.count) bytes"
    case .array(let values): "\(values.count) items"
    case .dictionary(let values): "\(values.count) keys"
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  var intValue: Int? {
    if case .integer(let value) = self { value } else { nil }
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  var arrayValue: [PlistValue]? {
    if case .array(let values) = self { values } else { nil }
  }

  var dictionaryValue: [String: PlistValue]? {
    if case .dictionary(let values) = self { values } else { nil }
  }

  var stringArrayValue: [String]? {
    guard let values = arrayValue else { return nil }
    let strings = values.compactMap(\.stringValue)
    return strings.count == values.count ? strings : nil
  }
}

enum PropertyListCoding {
  enum CodingError: LocalizedError {
    case notADictionary

    var errorDescription: String? {
      "The file is not a launchd property list. The top level must be a dictionary."
    }
  }

  static func dictionary(from data: Data) throws -> [String: PlistValue] {
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dictionary = object as? [String: Any] else { throw CodingError.notADictionary }
    return dictionary.compactMapValues(PlistValue.init)
  }

  static func xmlData(from dictionary: [String: PlistValue]) throws -> Data {
    // Foundation writes XML dictionaries with sorted keys, which keeps output deterministic.
    try PropertyListSerialization.data(
      fromPropertyList: dictionary.mapValues(\.foundationValue),
      format: .xml,
      options: 0
    )
  }
}
