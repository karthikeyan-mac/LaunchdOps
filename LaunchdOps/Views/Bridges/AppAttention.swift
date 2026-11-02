import AppKit

/// Bounces the Dock icon once when a long task finishes while LaunchdOps is in the background.
enum AppAttention {
  @MainActor
  static func requestIfInactive() {
    guard !NSApplication.shared.isActive else { return }
    NSApplication.shared.requestUserAttention(.informationalRequest)
  }
}
