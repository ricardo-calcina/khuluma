import Foundation

/// Whether and how to silence the system default output while a take
/// records, and when it is safe to put the sound back (Settings ›
/// Dictation › Mute other audio). The decisions only; `OutputMuter` (the
/// app) does the CoreAudio calls.
public enum OutputMutePolicy {
  public enum Plan: Equatable, Sendable {
    /// Nothing was done; the reason is logged.
    case none(reason: String)
    /// Set the device's mute property.
    case setMute
    /// Zero the main volume; put it back at `restore` afterwards.
    case zeroVolume(restore: Float)
  }

  /// Prefer the mute property; fall back to zeroing the volume when only
  /// that is settable. An already-muted (or already-silent) device is left
  /// alone: we would have nothing to restore to.
  public static func plan(muteSettable: Bool, currentlyMuted: Bool, volumeSettable: Bool, currentVolume: Float) -> Plan {
    if currentlyMuted { return .none(reason: "output is already muted") }
    if muteSettable { return .setMute }
    guard volumeSettable else { return .none(reason: "no mute or volume control on the output device") }
    if currentVolume <= 0.001 { return .none(reason: "output volume is already zero") }
    return .zeroVolume(restore: currentVolume)
  }

  /// Restore only while the device is still in the state `applied` left it
  /// in. If the user unmuted it or raised the volume meanwhile, leave it:
  /// their choice stands.
  public static func shouldRestore(applied: Plan, nowMuted: Bool, nowVolume: Float) -> Bool {
    switch applied {
    case .setMute: return nowMuted
    case .zeroVolume: return nowVolume <= 0.001
    case .none: return false
    }
  }
}
