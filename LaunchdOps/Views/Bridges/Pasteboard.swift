import AppKit

/// SwiftUI has no clipboard API for commands on macOS; this is the only place the app touches `NSPasteboard`.
enum Pasteboard {
  @MainActor
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// Plain text on the clipboard, read only when the user chooses a command that uses it.
  @MainActor
  static func string() -> String? {
    NSPasteboard.general.string(forType: .string)
  }
}
