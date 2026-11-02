import AppKit

/// Opens Console.app for Help ▸ View Logs. Console has no documented way for another app to set its
/// search, so the caller copies `search` to the clipboard for the admin to paste. Opening an app through
/// NSWorkspace is allowed in the sandbox and doesn't start a process of our own.
enum ConsoleLog {
  enum OpenError: LocalizedError {
    case consoleNotFound

    var errorDescription: String? {
      "Console couldn’t be found. Open it from /System/Applications/Utilities, then paste the search."
    }
  }

  /// Console's search syntax for this app's log messages.
  static var search: String {
    "subsystem:\(Bundle.main.bundleIdentifier ?? "com.karthikmac.LaunchdOps")"
  }

  @MainActor
  static func open() async throws {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
      throw OpenError.consoleNotFound
    }
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }
}
