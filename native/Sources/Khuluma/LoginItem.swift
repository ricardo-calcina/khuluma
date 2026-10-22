import Foundation
import ServiceManagement
import KhulumaCore

/// Start at Login. Opt-in, and macOS keeps the setting (System Settings →
/// General → Login Items), so there's nothing in config.toml. Registered by
/// bundle, so a rebuild in place keeps it; moving the app needs a re-toggle.
enum LoginItem {
  typealias Status = SMAppService.Status

  static var status: Status { AppRuntimePaths.isolated ? .notRegistered : SMAppService.mainApp.status }

  static func text(_ status: Status) -> String {
    switch status {
    case .enabled: return "on"
    case .requiresApproval: return "waiting for approval in System Settings"
    case .notRegistered: return "off"
    case .notFound: return "off (not found)"
    @unknown default: return "unknown (\(status.rawValue))"
    }
  }

  /// Turns it on or off. If macOS wants the user's say-so, opens the place
  /// in System Settings.
  static func toggle() throws {
    guard !AppRuntimePaths.isolated else {
      throw NSError(domain: "Khuluma", code: 6, userInfo: [
        NSLocalizedDescriptionKey: "Start at Login is unavailable for an isolated test instance",
      ])
    }
    let service = SMAppService.mainApp
    switch service.status {
    case .enabled:
      try service.unregister()
    case .requiresApproval:
      // Registered, but macOS wants the user's say-so: show where.
      SMAppService.openSystemSettingsLoginItems()
    default:
      try service.register()
      if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
  }
}
