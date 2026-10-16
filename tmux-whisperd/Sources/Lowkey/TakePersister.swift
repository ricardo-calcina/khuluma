import Foundation
import LowkeyCore

/// History, bench and usage for finished takes: spooled to disk first, then
/// recorded with `inline record`, one take at a time, after delivery.
final class TakePersister {
  /// `inline record` runs here. Quit waits for it to drain.
  let queue = DispatchQueue(label: "lowkey.persist", qos: .utility)
  private let cli: CLIBridge
  private let pending = PendingRecords.standard

  init(cli: CLIBridge) {
    self.cli = cli
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
    queue.async { [pending, cli] in
      if Self.record(record, cli: cli), let spooled {
        pending.remove(spooled)
      }
    }
    return spooled != nil
  }

  /// Replays takes a previous run delivered but could not record.
  func replayLeftovers() {
    queue.async { [pending, cli] in
      let (records, dropped) = pending.leftovers()
      for name in dropped {
        Log.write("persist: dropped stale or unreadable pending record \(name)")
      }
      for (url, record) in records where Self.record(record, cli: cli) {
        pending.remove(url)
        Log.write("persist: replayed take \(record.takeId) from a previous run")
      }
    }
  }

  /// Runs `inline record`; true once the take is fully recorded.
  private static func record(_ record: TakeRecord, cli: CLIBridge) -> Bool {
    do {
      let result = try cli.record(record)
      let wantsUsage = record.status == "ok" && record.delivered
      if wantsUsage && !(result.usageRecorded && result.historySaved) {
        Log.write("persist: take \(record.takeId) partly recorded (usage \(result.usageRecorded), history \(result.historySaved))")
      }
      // Take ids are deduplicated, so a retry redoes only what failed
      // (usage or history): keep the take for the next launch.
      if wantsUsage && !(result.usageRecorded && (result.historySaved || record.usageOnly == true)) {
        Log.write("persist: take \(record.takeId) not fully recorded yet (kept for the next launch)")
        return false
      }
      // A recovered take exists only in history: keep it spooled until saved.
      if record.status == "recovered" && !result.historySaved {
        Log.write("persist: recovered take \(record.takeId) not in history yet (kept for the next launch)")
        return false
      }
      return true
    } catch {
      Log.write("persist: take \(record.takeId) not recorded yet (kept for the next launch): \(error.localizedDescription)")
      return false
    }
  }
}
