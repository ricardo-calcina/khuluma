import Foundation
import KhulumaCore

/// What a take optionally does to the rest of the Mac while it records
/// (Settings › Dictation › While recording): silences the output after the
/// start chime and keeps the Mac awake. Owned by AppController; `end` is
/// idempotent so every take-ending path makes the one call.
final class RecordingEnvironment {
  private let muter: OutputMuter
  private var activity: NSObjectProtocol?
  private var muted = false
  private var takeID: UUID?

  init(muter: OutputMuter = OutputMuter()) {
    self.muter = muter
  }

  /// A previous run that crashed mid-take may have left the output muted.
  func restoreAfterLaunch() {
    muter.restorePending()
  }

  /// Called once the take exists, on main.
  func begin(takeID: UUID, keepAwake: Bool) {
    self.takeID = takeID
    if keepAwake, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled], reason: "Khuluma is recording")
    }
  }

  /// Mutes other audio for this take; ignored once the take has ended.
  func mute(takeID: UUID) {
    guard self.takeID == takeID, !muted else { return }
    muted = true
    muter.mute()
  }

  /// Ends the mute and the wake block. Safe to call from every take-ending
  /// path, and again.
  func end() {
    takeID = nil
    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
    if muted {
      muted = false
      muter.restore()
    }
  }
}
