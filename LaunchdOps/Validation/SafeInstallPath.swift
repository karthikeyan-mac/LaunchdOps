import Foundation

/// The one validator for paths and names that end up on customer Macs: payload file names, payload destinations
/// (absolute in package mode, a subfolder in DDM mode), install paths in the package payload and log folders.
/// A value passes only in its canonical form, so no later step can normalize it into something else.
enum SafeInstallPath {
  enum Problem: Equatable, Sendable {
    case empty
    case relative
    case absolute
    case doubleSlash
    case dotComponent
    case controlCharacter
    case tooLong

    var message: String {
      switch self {
      case .empty: "is empty"
      case .relative: "must be an absolute path starting with /"
      case .absolute: "must be a folder inside the task folder, not an absolute path"
      case .doubleSlash: "contains //"
      case .dotComponent: "contains a . or .. folder, or a name starting with a dot"
      case .controlCharacter: "contains a line break or other control character"
      case .tooLong: "is too long for macOS (255 bytes per name, 1,024 per path)"
      }
    }
  }

  static let maximumNameBytes = 255
  static let maximumPathBytes = 1024

  /// One file or folder name: not empty, not starting with a dot, no slash or control characters.
  static func problem(withName name: String) -> Problem? {
    if name.isEmpty { return .empty }
    if name.hasPrefix(".") { return .dotComponent }
    if name.contains("/") { return .doubleSlash }
    if hasControlCharacter(name) { return .controlCharacter }
    if name.utf8.count > maximumNameBytes { return .tooLong }
    return nil
  }

  /// An absolute folder such as `/usr/local/libexec`. A single trailing slash is allowed and ignored.
  static func problem(withFolder path: String) -> Problem? {
    if path.isEmpty { return .empty }
    guard path.hasPrefix("/") else { return .relative }
    return problem(withAbsolutePath: path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
  }

  /// A DDM destination: a folder inside the task folder, or empty for the task folder itself.
  static func problem(withSubfolder path: String) -> Problem? {
    if path.isEmpty { return nil }
    if path.hasPrefix("/") { return .absolute }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return problem(withComponents: trimmed)
  }

  /// A full absolute install path such as `/Library/LaunchDaemons/com.example.job.plist`, no trailing slash.
  static func problem(withAbsolutePath path: String) -> Problem? {
    if path.isEmpty { return .empty }
    guard path.hasPrefix("/") else { return .relative }
    if path == "/" { return nil }
    return problem(withComponents: String(path.dropFirst()))
  }

  private static func problem(withComponents path: String) -> Problem? {
    if path.isEmpty { return .empty }
    if path.utf8.count > maximumPathBytes { return .tooLong }
    if hasControlCharacter(path) { return .controlCharacter }
    for component in path.split(separator: "/", omittingEmptySubsequences: false) {
      if component.isEmpty { return .doubleSlash }
      if component == "." || component == ".." { return .dotComponent }
      if component.utf8.count > maximumNameBytes { return .tooLong }
    }
    return nil
  }

  private static func hasControlCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}
