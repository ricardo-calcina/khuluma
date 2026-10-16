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
  /// use now (e.g. after `tmux-whisper autosend off`), not launch-time values.
  let settings: SettingsFetch?
  /// Published before capture starts and removed when the take ends, so
  /// the CLI never swaps the daemon out mid-take.
  let marker: TakeMarker?
  /// The start chime: played once, when capture is confirmed.
  let chime: OneShot

  func delivery(_ base: Delivery) -> Delivery {
    retargeted ? base.restoringOriginalApp() : base
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

/// `tmux-whisper app-config --json`, fetched in the background.
final class SettingsFetch: @unchecked Sendable {
  enum Outcome {
    case config(AppConfig)
    /// The CLI isn't the one Khuluma was built with: no take may use it.
    case mismatch(AppContract.Mismatch)
    /// Not read (in time): the CLI path reads its own settings.
    case unavailable(String)
  }

  private let done = DispatchGroup()
  private var outcome: Outcome = .unavailable("settings unavailable")

  /// `onMismatch` runs as soon as a mismatch is known, so later presses
  /// are refused even if no take waits for this fetch.
  private let onMismatch: (AppContract.Mismatch) -> Void

  init(cli: CLIBridge, queue: DispatchQueue, onMismatch: @escaping (AppContract.Mismatch) -> Void) {
    self.onMismatch = onMismatch
    done.enter()
    queue.async {
      do {
        self.outcome = .config(try cli.appConfig())
      } catch let mismatch as AppContract.Mismatch {
        self.outcome = .mismatch(mismatch)
        self.onMismatch(mismatch)
      } catch {
        self.outcome = .unavailable(error.localizedDescription)
      }
      self.done.leave()
    }
  }

  func wait(timeout: TimeInterval) -> Outcome {
    guard done.wait(timeout: .now() + timeout) == .success else { return .unavailable("timed out reading settings") }
    return outcome
  }
}
