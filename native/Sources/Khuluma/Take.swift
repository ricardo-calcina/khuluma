import AppKit
import Foundation
import KhulumaCore

/// A recording in progress, and what it carries into processing.
struct Take {
  let hotkeyAt: Double
  let startedAt: Double
  let startedEpochMs: Int
  let startupMs: Int
  let originalApp: NSRunningApplication?
  /// Khuluma was in front at the hotkey, so `originalApp` is the app before
  /// it and must be re-activated for delivery.
  let retargeted: Bool
  /// Settings read while recording, so each take uses what the CLI would
  /// use now (e.g. after `khuluma autosend off`), not launch-time values.
  let settings: SettingsFetch?
  /// Published before capture starts and removed when the take ends, so
  /// the CLI never swaps the daemon out mid-take.
  let marker: TakeMarker?
  /// The start chime: played once, when capture is confirmed.
  let chime: OneShot
  /// Stopped with the paste-only shortcut: paste, never send.
  var pasteOnly = false

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
}

/// The settings (settings.json), read in the background while recording.
final class SettingsFetch: @unchecked Sendable {
  enum Outcome {
    case config(AppConfig)
    /// The CLI isn't the one Khuluma was built with: no take may use it.
    /// (Settings no longer come from the CLI; kept for the CLI route.)
    case mismatch(AppContract.Mismatch)
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
