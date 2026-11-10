import AppKit
import Foundation
import KhulumaCore

/// How the take was started: a toggle press, or the hold-to-talk key.
enum TakeMode {
  case toggle, hold
}

/// A recording in progress, and what it carries into processing.
struct Take {
  /// Tells takes apart, so a delayed hold-release finish can't stop the
  /// next take.
  let id: UUID
  var mode: TakeMode = .toggle
  let hotkeyAt: Double
  let startedAt: Double
  let startedEpochMs: Int
  let startupMs: Int
  let originalApp: NSRunningApplication?
  /// Khuluma was in front at the hotkey, so `originalApp` is the app before
  /// it and must be re-activated for delivery.
  let retargeted: Bool
  /// Settings read while recording, so each take uses the current
  /// settings.json (e.g. after a Settings change), not launch-time values.
  let settings: SettingsFetch?
  /// Published before capture starts and removed when the take ends: the
  /// processing dir shows a take in progress.
  let marker: TakeMarker?
  /// The start chime: played once, when capture is confirmed.
  let chime: OneShot
  /// Stopped with the paste-only shortcut: paste, never send.
  var pasteOnly = false
  /// "Transcribe while recording" side-band, when it was on at take start.
  var live: LiveTake?

  func delivery(_ base: Delivery) -> Delivery {
    let delivery = retargeted ? base.restoringOriginalApp() : base
    return pasteOnly ? delivery.withoutSending() : delivery
  }
}

/// A take stopped for Quit whose audio couldn't be written yet.
struct UnsavedTake {
  let samples: [Float]
  let takeId: String
  let startedEpochMs: Int
  let startupMs: Int
  let app: String?
  let marker: TakeMarker?
  /// Its spool file is removed once the recovered copy is safely written.
  let live: LiveTake?
}

/// The settings (settings.json), read in the background while recording.
final class SettingsFetch: @unchecked Sendable {
  enum Outcome {
    case config(AppConfig)
    /// Not read in time.
    case unavailable(String)
  }

  private let done = DispatchGroup()
  private var outcome: Outcome = .unavailable("settings unavailable")

  init(queue: DispatchQueue, load: @escaping () -> AppConfig) {
    done.enter()
    queue.async {
      self.outcome = .config(load())
      self.done.leave()
    }
  }

  func wait(timeout: TimeInterval) -> Outcome {
    guard done.wait(timeout: .now() + timeout) == .success else { return .unavailable("timed out reading settings") }
    return outcome
  }
}
