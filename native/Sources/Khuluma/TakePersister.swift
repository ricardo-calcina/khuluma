import Foundation
import KhulumaCore

/// History and usage for finished takes: spooled to disk first, then written
/// by `TakeRecorder` into the app's own data folder, one take at a time,
/// after delivery. Each destination's done flag is kept in the spool, so a
/// record is dropped only once everything it needs is written.
final class TakePersister {
  /// Recording runs here, one take at a time. Quit waits for it to drain.
  let queue = DispatchQueue(label: "khuluma.persist", qos: .utility)
  private let pending = PendingRecords.standard
  private let settingsLock = NSLock()
  private var settings = TakeRecorder.Settings.from(nil)
  private let replayGate = ReplayGate()

  /// Takes on the settings the recorder needs, and releases the launch
  /// replay the first time. Retention stays 7/2 days until the settings
  /// slice reads it from settings.json.
  func adopt(_ config: AppConfig) {
    let fresh = TakeRecorder.Settings.from(config, historyRetentionDays: 7, audioRetentionDays: 2)
    settingsLock.lock()
    settings = fresh
    settingsLock.unlock()
    replayGate.settle()
  }

  /// Settings could not be read: replay with the defaults rather than never.
  func settingsUnavailable() {
    replayGate.settle()
  }

  private var recorder: TakeRecorder {
    settingsLock.lock()
    defer { settingsLock.unlock() }
    return TakeRecorder.standard(settings: settings)
  }

  /// Returns whether the record is durably spooled (so the caller may drop
  /// any other copy, e.g. a recovered take's audio).
  @discardableResult
  func persist(_ record: TakeRecord) -> Bool {
    // Spooled first, so a quit that can't wait or a crash replays it later.
    let spooled: URL?
    do {
      spooled = try pending.save(record)
    } catch {
      spooled = nil
      Log.write("persist: take \(record.takeId) not spooled: \(error.localizedDescription)")
    }
    queue.async { [self] in
      _ = recorder.apply(PendingTake(record: record), spooled: spooled, pending: pending) { Log.write("persist: \($0)") }
    }
    return spooled != nil
  }

  /// Replays takes a previous run delivered but could not fully record,
  /// including bare records spooled by build 415 (nothing done yet). Waits
  /// for the first settings (keep_logs decides the debug archive).
  func replayLeftovers() {
    replayGate.request { [self] in
      queue.async { [self] in
        let (records, quarantined) = pending.leftovers()
        for name in quarantined {
          Log.write("persist: quarantined unreadable pending file \(name)")
        }
        for (url, take) in records
        where recorder.apply(take, spooled: url, pending: pending, log: { Log.write("persist: \($0)") }) {
          Log.write("persist: replayed take \(take.record.takeId) from a previous run")
        }
      }
    }
  }
}
