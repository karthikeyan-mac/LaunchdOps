import Foundation
import OSLog

/// The app's loggers, one category per area, all under the app's subsystem, so Console can show everything
/// (`subsystem:com.karthikmac.LaunchdOps`) or one area (add `category:Export`). File contents, environment values,
/// keys and tokens are never logged; file names, labels, identifiers and counts are public; identity names, which
/// contain a person's name, are private.
enum Log {
  static let subsystem = Bundle.main.bundleIdentifier ?? "com.karthikmac.LaunchdOps"

  /// Launch, windows, menus and settings.
  static let app = Logger(subsystem: subsystem, category: "App")
  /// Loading, saving, importing and deleting jobs.
  static let library = Logger(subsystem: subsystem, category: "Library")
  /// Building and saving export folders, plists and projects.
  static let export = Logger(subsystem: subsystem, category: "Export")
  /// Keychain signing identities for packages and profiles.
  static let signing = Logger(subsystem: subsystem, category: "Signing")
  /// Apple's notary service: submission, upload, status and result.
  static let notarization = Logger(subsystem: subsystem, category: "Notarization")
  /// Ticket lookup and stapling.
  static let stapling = Logger(subsystem: subsystem, category: "Stapling")

  /// Milliseconds since `start`, for timing log lines.
  static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
  }
}
