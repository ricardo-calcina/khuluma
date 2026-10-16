import Foundation

/// Takes that were stopped and are queued or being transcribed: until their
/// record reaches the pending spool (or another store takes the audio), they
/// exist only in memory. At Quit, `saveAll` writes each one to
/// `RecoveredTakes`, so a take Quit's drain can't finish is transcribed at
/// the next launch. A take that does finish calls `finish`, which deletes
/// that copy, so it is never transcribed twice. Thread-safe: takes finish on
/// the work queue while Quit saves on main.
public final class InFlightTakes: @unchecked Sendable {
  public let store: RecoveredTakes
  private let lock = NSLock()
  private var takes: [String: Entry] = [:]

  private struct Entry {
    let samples: [Float]
    /// The copy written at Quit, if any.
    var saved: URL?
  }

  public init(store: RecoveredTakes) {
    self.store = store
  }

  /// Tracks a stopped take's audio and returns its take id: used for the
  /// saved copy's name and the take's record, so a copy that outlives its
  /// spooled record (a crash between the two) is recorded once.
  @discardableResult
  public func add(samples: [Float], takeId: String = UUID().uuidString.lowercased()) -> String {
    lock.withLock { takes[takeId] = Entry(samples: samples) }
    return takeId
  }

  public var count: Int {
    lock.withLock { takes.count }
  }

  /// Copies written for takes still in flight: not leftovers yet, so a
  /// recovery pass must leave them alone.
  public func savedFiles() -> Set<URL> {
    lock.withLock { Set(takes.values.compactMap(\.saved)) }
  }

  /// Writes every take not saved yet. Returns how many were written now and
  /// how many couldn't be (those stay unsaved; calling again retries them).
  @discardableResult
  public func saveAll(at date: Date = Date()) -> (saved: Int, failed: Int) {
    // Held across the writes, so a take that finishes meanwhile waits and
    // then deletes its new copy.
    lock.withLock {
      var saved = 0
      var failed = 0
      for (takeId, entry) in takes where entry.saved == nil {
        if let url = try? store.save(samples: entry.samples, takeId: takeId, at: date) {
          takes[takeId]?.saved = url
          saved += 1
        } else {
          failed += 1
        }
      }
      return (saved, failed)
    }
  }

  /// The take ended (its record is spooled, another store holds its audio,
  /// or it failed): stop tracking it and delete its copy, if one was saved.
  public func finish(_ takeId: String) {
    let saved = lock.withLock { takes.removeValue(forKey: takeId)?.saved }
    if let saved { store.remove(saved) }
  }

  /// Hands the take's audio to `RecoveredTakes` for good (to transcribe
  /// later): reuses the copy saved at Quit or writes one now, then stops
  /// tracking the take without deleting it. On failure the take stays
  /// tracked and unsaved.
  public func keep(_ takeId: String, at date: Date = Date()) throws -> URL {
    try lock.withLock {
      guard let entry = takes[takeId] else { throw CocoaError(.fileNoSuchFile) }
      let url = try entry.saved ?? store.save(samples: entry.samples, takeId: takeId, at: date)
      takes.removeValue(forKey: takeId)
      return url
    }
  }
}
