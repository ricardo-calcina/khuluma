import AppKit
import ApplicationServices
import AVFoundation
import KhulumaCore

/// Launch-time permission checks and the Settings panes that fix them.
enum Permissions {
  static var microphoneStatus: PermissionPolicy.MicrophoneStatus {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .authorized
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  /// Asks for the keyboard (post-event) permission once if it isn't granted
  /// and returns a menu notice while it's still missing.
  static func checkKeyboardAtLaunch(
    preflight: () -> Bool = { CGPreflightPostEventAccess() },
    request: () -> Bool = { CGRequestPostEventAccess() }
  ) -> PermissionPolicy.Notice? {
    if preflight() { return nil }
    Log.write("permission: no access to post key events; requested once")
    _ = request()
    return preflight() ? nil : PermissionPolicy.keyboardNotice
  }

  static func open(_ pane: PermissionPolicy.Pane) {
    if let url = URL(string: pane.url) { NSWorkspace.shared.open(url) }
  }
}
