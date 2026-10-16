import Foundation

/// Takes that were stopped and are queued or being transcribed: until their
/// record reaches the pending spool (or another store takes the audio), they
/// exist only in memory. At Quit, `saveAll` writes each one to
/// `RecoveredTakes`, so a take Quit's drain can't finish is transcribed at
/// the next launch. A take that settles during the drain calls `finish`,
/// which deletes that copy, so it isn't transcribed twice; one that fails
/// calls `release`, which leaves the copy to be recovered.
///
/// This is the only owner of audio not on disk yet: a take whose audio
/// must outlive it (a failure once Quit has begun, a `keep` that couldn't
/// write) stays here, *held*, until `saveAll` writes it or `discardHeld`
/// gives it up. Thread-safe: takes end on the work queue while Quit saves
/// on main.
public final class InFlightTakes: @unchecked Sendable {
  public let store: RecoveredTakes
  private let lock = NSLock()
  private var takes: [String: Entry] = [:]
  /// Set by the first `saveAll` (Quit): from then on no take's audio is
  /// dropped without a copy on disk.
  private var preserving = false

  private struct Entry {
    let samples: [Float]
    /// The copy written at Quit, if any.
    var saved: URL?
    /// The take is over; its audio waits here for `saveAll`.
    var held = false
  }

  public init(store: RecoveredTakes) {
    self.store = store
  }

  /// Tracks a stopped take's audio and returns its id (its saved copy's
  /// name). Not the take's record id: a copy recovered next to a record
  /// (a crash between the two, or a take that failed) must not be dropped
  /// as that record's duplicate, so the worst case is a second history entry.
  @discardableResult
  public func add(samples: [Float], takeId: String = UUID().uuidString.lowercased()) -> String {
    lock.withLock { takes[takeId] = Entry(samples: samples) }
    return takeId
  }

  /// Takes still running or held.
  public var count: Int {
    lock.withLock { takes.count }
  }

  /// Takes that are over but whose audio couldn't be written yet.
  public var held: Int {
    lock.withLock { takes.values.filter(\.held).count }
  }

  /// Copies written for takes still in flight: not leftovers yet, so a
  /// recovery pass must leave them alone.
  public func savedFiles() -> Set<URL> {
    lock.withLock { Set(takes.values.compactMap(\.saved)) }
  }

  /// Writes every take not saved yet; a held take, once written, is the
  /// store's. Returns how many were written now and how many couldn't be
  /// (those stay; calling again retries them).
  @discardableResult
  public func saveAll(at date: Date = Date()) -> (saved: Int, failed: Int) {
    // Held across the writes, so a take that finishes meanwhile waits and
    // then deletes its new copy.
    lock.withLock {
      preserving = true
      var saved = 0
      var failed = 0
      for (takeId, entry) in takes where entry.saved == nil {
        if let url = try? store.save(samples: entry.samples, takeId: takeId, at: date) {
          if entry.held {
            takes.removeValue(forKey: takeId)
          } else {
            takes[takeId]?.saved = url
          }
          saved += 1
        } else {
          failed += 1
        }
      }
      return (saved, failed)
    }
  }

  /// The take is settled (its record is spooled, it had no speech, or
  /// another store holds its audio): stop tracking it and delete its copy,
  /// if one was saved.
  public func finish(_ takeId: String) {
    let saved = lock.withLock { takes.removeValue(forKey: takeId)?.saved }
    if let saved { store.remove(saved) }
  }

  /// The take ended without settling (it failed). A copy saved at Quit is
  /// left for the next launch to recover. Without one, the audio is held
  /// for `saveAll` once Quit has begun (or already by a failed `keep`);
  /// before that it goes, as for any failed take.
  public func release(_ takeId: String) {
    lock.withLock {
      guard let entry = takes[takeId], !entry.held else { return }
      if entry.saved == nil && preserving {
        takes[takeId]?.held = true
      } else {
        takes.removeValue(forKey: takeId)
      }
    }
  }

  /// Hands the take's audio to `RecoveredTakes` for good (to transcribe
  /// later): reuses the copy saved at Quit or writes one now, then stops
  /// tracking the take without deleting it. If it can't be written, the
  /// take is held for the next `saveAll`.
  public func keep(_ takeId: String, at date: Date = Date()) throws -> URL {
    try lock.withLock {
      guard let entry = takes[takeId] else { throw CocoaError(.fileNoSuchFile) }
      do {
        let url = try entry.saved ?? store.save(samples: entry.samples, takeId: takeId, at: date)
        takes.removeValue(forKey: takeId)
        return url
      } catch {
        takes[takeId]?.held = true
        throw error
      }
    }
  }

  /// Gives up held takes (the user chose to discard them). Returns how many.
  @discardableResult
  public func discardHeld() -> Int {
    lock.withLock {
      let held = takes.filter { $0.value.held }.map(\.key)
      held.forEach { takes.removeValue(forKey: $0) }
      return held.count
    }
  }
}
