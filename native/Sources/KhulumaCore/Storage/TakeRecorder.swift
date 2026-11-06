import Foundation

/// Records one finished take in the app's own data folder with the rules the
/// CLI's `inline record` used: usage only for a delivered `ok` take, history
/// for a delivered `ok` take or a `recovered` one, none for `usage_only`.
/// Each destination is written under `<root>/.data.lock` and is idempotent by
/// take id, so a replay redoes only what is missing. The caller serializes
/// calls (one queue); the lock keeps a second app copy from interleaving.
public struct TakeRecorder: Sendable {
  public struct Settings: Equatable, Sendable {
    public var historyRetentionDays: Int
    public var audioRetentionDays: Int
    public var keepLogs: Bool

    public init(historyRetentionDays: Int = 7, audioRetentionDays: Int = 2, keepLogs: Bool = false) {
      self.historyRetentionDays = historyRetentionDays
      self.audioRetentionDays = audioRetentionDays
      self.keepLogs = keepLogs
    }

    /// keep_logs from the app's settings (or `KHULUMA_KEEP_LOGS=1`).
    /// Retention is a plain input: 7 days of history and 2 of archived audio
    /// until the settings slice passes the real values from settings.json.
    public static func from(_ config: AppConfig?, historyRetentionDays: Int = 7, audioRetentionDays: Int = 2,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Settings {
      Settings(historyRetentionDays: historyRetentionDays, audioRetentionDays: audioRetentionDays,
               keepLogs: environment["KHULUMA_KEEP_LOGS"] == "1" || config?.transcription.keepLogs == true)
    }
  }

  public enum Step: Equatable, Sendable {
    case notNeeded
    case written
    case alreadyThere
    case failed(String)

    public var isDone: Bool {
      if case .failed = self { return false }
      return true
    }
  }

  public struct Result: Equatable, Sendable {
    public var history: Step
    public var usage: Step
    public var complete: Bool { history.isDone && usage.isDone }
  }

  public let root: URL
  public var settings: Settings
  public var now: @Sendable () -> Date
  public var timeZone: TimeZone
  public var trash: @Sendable (URL) throws -> Void
  public var lockTimeout: TimeInterval = 5
  public var syncDirectory: DataFiles.SyncDirectory = DataFiles.syncDirectory
  /// Folders the app's working WAVs live in (deleted once saved).
  public var temporaryRoots: [URL]

  public init(root: URL, settings: Settings = Settings(), now: @escaping @Sendable () -> Date = { Date() },
              timeZone: TimeZone = .current,
              trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
              temporaryRoots: [URL] = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: NSTemporaryDirectory()), AppRuntimePaths.temporary]) {
    self.root = root
    self.settings = settings
    self.now = now
    self.timeZone = timeZone
    self.trash = trash
    self.temporaryRoots = temporaryRoots
  }

  /// `~/Library/Application Support/Khuluma` (or the isolation override).
  public static func standard(settings: Settings) -> TakeRecorder {
    TakeRecorder(root: AppRuntimePaths.support, settings: settings)
  }

  /// What the CLI had already done per take, from the one-time import
  /// (`legacy-take-ids.json`: `{"history": [...], "usage": [...]}`). Empty
  /// when absent or unreadable. The earlier format (a plain array, the union
  /// of all three CLI ledgers, written only by pre-release builds of this
  /// branch) is ignored: it includes the bench ledger, which the CLI marks
  /// before saving history, so it proves nothing. Ignoring it risks at worst
  /// a duplicate history entry (usage.json dedups counts by take id itself),
  /// never lost text.
  public func legacyDone() -> (history: Set<String>, usage: Set<String>) {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(LegacyImport.legacyTakeIDsName)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
    return (Set(object["history"] as? [String] ?? []), Set(object["usage"] as? [String] ?? []))
  }

  public var lockURL: URL { root.appendingPathComponent(".data.lock") }
  public var historyDirectory: URL { root.appendingPathComponent("history", isDirectory: true) }
  public var usageURL: URL { root.appendingPathComponent("usage.json") }

  public var history: HistoryWriter {
    var writer = HistoryWriter(directory: historyDirectory, retentionDays: settings.historyRetentionDays, now: now,
                               timeZone: timeZone, trash: trash)
    writer.syncDirectory = syncDirectory
    return writer
  }
  public var usage: UsageLedger {
    var ledger = UsageLedger(url: usageURL, now: now, timeZone: timeZone)
    ledger.syncDirectory = syncDirectory
    return ledger
  }
  public var archive: DebugArchive {
    DebugArchive(directory: historyDirectory.appendingPathComponent("inline-debug", isDirectory: true),
                 audioRetentionDays: settings.audioRetentionDays, now: now, timeZone: timeZone)
  }

  /// The take's result is durably saved: a history entry (written only for
  /// takes with text) or a spooled record that carries text or no-speech.
  /// A failed-transcription record doesn't count: its audio still matters.
  /// A no-speech take leaves no history entry once its spool file is gone, so
  /// a recovered copy of one costs at most one more transcription; it goes to
  /// history without pasting.
  public func isRecorded(takeId: String, pending: PendingRecords) -> Bool {
    guard !takeId.isEmpty else { return false }
    // History saved by the CLI before the import (build 415 and earlier).
    if legacyDone().history.contains(takeId) { return true }
    // Spool first, history second. Replay writes history (fsynced, directory
    // synced) before it removes the spool file, so a take is always in at
    // least one of them: if the spool no longer holds it, the history write
    // that preceded the removal is already visible to the second check.
    // (Checking history first could miss it between the two.)
    let spooled = pending.leftovers().records.contains {
      let r = $0.take.record
      return r.takeId == takeId && (Self.needsHistory(r) || r.status == "no_speech")
    }
    if spooled { return true }
    return history.entryURL(takeId: takeId) != nil
  }

  public static func wantsUsage(_ r: TakeRecord) -> Bool { r.status == "ok" && r.delivered }
  public static func needsHistory(_ r: TakeRecord) -> Bool {
    r.usageOnly != true && (wantsUsage(r) || r.status == "recovered" || keepsUndelivered(r))
  }
  /// A take whose paste failed keeps its text in history (marked not
  /// delivered) so it survives the clipboard being overwritten. Never counted.
  static func keepsUndelivered(_ r: TakeRecord) -> Bool {
    r.status == "paste_failed" && !r.delivered && !r.text.isEmpty
  }

  /// Applies the record to every destination not already `done`.
  /// `protectedTakeIds`: takes still in the spool, never pruned from usage's
  /// take ids or from history (see `UsageLedger.Delivery.protectedTakeIds`).
  public func record(_ r: TakeRecord, done given: PendingTake.Done = PendingTake.Done(), protectedTakeIds: Set<String> = [],
                     log: @escaping (String) -> Void = { _ in }) -> Result {
    var result = Result(history: .notNeeded, usage: .notNeeded)
    // What the CLI's ledgers prove it already did for this take, per
    // destination: a replayed build-415 pending record redoes only the rest.
    var done = given
    if !r.takeId.isEmpty {
      let legacy = legacyDone()
      if legacy.history.contains(r.takeId), !done.history {
        done.history = true
        log("record: take \(r.takeId) history was saved before the import; not saved again")
      }
      if legacy.usage.contains(r.takeId), !done.usage {
        done.usage = true
        log("record: take \(r.takeId) was counted before the import; not counted again")
      }
    }
    let ms = { (v: Int) in max(v, 0) }

    if Self.wantsUsage(r) {
      if done.usage {
        result.usage = .alreadyThere
      } else {
        var elapsed = ms(r.totalMs)
        if let start = r.startedAtMs, let end = r.deliveredAtMs, start >= 0, end >= 0 { elapsed = max(end - start, 0) }
        let delivery = UsageLedger.Delivery(text: r.text, recordMs: ms(r.recordMs), fullElapsedMs: elapsed,
                                            takeId: r.takeId, localDate: r.deliveredLocalDate,
                                            protectedTakeIds: protectedTakeIds,
                                            speechMs: r.speechMs.map { min(ms($0), ms(r.recordMs)) })
        do {
          let outcome = try DataFiles.withLock(lockURL, timeout: lockTimeout) {
            try usage.record(delivery) { log("usage: \($0)") }
          }
          result.usage = outcome == .duplicate ? .alreadyThere : .written
        } catch {
          result.usage = .failed(error.localizedDescription)
          log("usage: take \(r.takeId) not counted: \(error.localizedDescription)")
        }
      }
    }

    let wav = r.wavPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    if Self.needsHistory(r) {
      if done.history {
        result.history = .alreadyThere
      } else {
        result.history = saveHistory(r, wav: wav, protectedTakeIds: protectedTakeIds, log: log)
      }
      if result.history.isDone, let wav {
        releaseWorkingAudio(wav, log: log)
      }
    } else if r.usageOnly != true, settings.keepLogs, let wav, FileManager.default.fileExists(atPath: wav.path) {
      // A take with no transcript to save (no speech, failed): keep only its
      // debug copy, then release the working file.
      if archive.archive(wav: wav, record: r, captureGapMs: captureGap(r)) != nil, r.status != "recovered" {
        releaseWorkingAudio(wav, log: log)
      }
    }
    return result
  }

  private func captureGap(_ r: TakeRecord) -> Int? {
    guard let capture = r.captureWavMs, capture >= 0 else { return nil }
    return capture - max(r.recordMs, 0)
  }

  private func saveHistory(_ r: TakeRecord, wav: URL?, protectedTakeIds: Set<String>, log: @escaping (String) -> Void) -> Step {
    do {
      return try DataFiles.withLock(lockURL, timeout: lockTimeout) {
        let writer = history
        if !r.takeId.isEmpty, writer.entryURL(takeId: r.takeId) != nil { return .alreadyThere }
        var audio: [(String, HistoryWriter.AudioValue)] = []
        if let v = r.captureWavMs, v >= 0 { audio.append(("capture_wav_ms", .int(v))) }
        if let v = r.captureWavBytes, v >= 0 { audio.append(("capture_wav_bytes", .int(v))) }
        if let gap = captureGap(r), gap >= 0 { audio.append(("capture_gap_to_record_ms", .int(gap))) }
        if settings.keepLogs, let wav, FileManager.default.fileExists(atPath: wav.path) {
          let a = archive
          if let saved = a.archive(wav: wav, record: r, captureGapMs: captureGap(r)) {
            if let v = saved.wavMs { audio.append(("archive_wav_ms", .int(v))) }
            if let v = saved.wavBytes { audio.append(("archive_wav_bytes", .int(v))) }
            audio.append(("wav_retention_days", .int(a.audioRetentionDays)))
            audio.append(("debug_archive_prefix", .string(saved.prefix)))
            audio.append(("retention_note", .string(a.retentionNote)))
          }
        }
        let ms = { (v: Int) in max(v, 0) }
        var metrics: [(String, Int)] = [("record_ms", ms(r.recordMs))]
        if let speech = r.speechMs { metrics.append(("speech_ms", min(ms(speech), ms(r.recordMs)))) }
        metrics += [("transcribe_ms", ms(r.transcribeMs)), ("clean_ms", ms(r.cleanMs)),
                    ("paste_ms", ms(r.pasteMs)), ("total_ms", ms(r.totalMs))]
        var entry = HistoryWriter.Entry(
          app: (r.app?.isEmpty ?? true) ? "current" : r.app!, raw: r.rawText, processed: r.text,
          takeId: r.takeId.isEmpty ? nil : r.takeId,
          metrics: metrics,
          audio: audio)
        entry.delivered = !Self.keepsUndelivered(r)
        switch try writer.save(entry, protectedTakeIds: protectedTakeIds, log: log) {
        case .saved: return .written
        case .alreadySaved: return .alreadyThere
        }
      }
    } catch {
      log("history: take \(r.takeId) not saved: \(error.localizedDescription)")
      return .failed(error.localizedDescription)
    }
  }

  private func releaseWorkingAudio(_ wav: URL, log: (String) -> Void) {
    if !DebugArchive.deleteWorkingAudio(wav.path, roots: temporaryRoots) {
      log("history: left working audio in place (not an owned temporary take file)")
    }
    do { try archive.expire() } catch { log("history: audio expiry failed: \(error.localizedDescription)") }
  }
}

extension TakeRecorder {
  /// Records a spooled take: writes what it still needs, saves each newly
  /// done destination's flag, and removes the spool file once everything is
  /// done. Every take still in the spool is protected from pruning. Returns
  /// whether the take is fully recorded.
  public func apply(_ take: PendingTake, spooled: URL?, pending: PendingRecords,
                    log: @escaping (String) -> Void = { _ in }) -> Bool {
    var protected = Set(pending.leftovers().records.map(\.take.record.takeId))
    protected.insert(take.record.takeId)
    let result = record(take.record, done: take.done, protectedTakeIds: protected, log: log)
    if let spooled {
      for (destination, step) in [(PendingTake.Destination.history, result.history), (.usage, result.usage)]
      where step.isDone && !take.done[destination] {
        do { try pending.markDone(spooled, destination) } catch {
          log("take \(take.record.takeId) \(destination.rawValue) done flag not saved: \(error.localizedDescription)")
        }
      }
    }
    guard result.complete else {
      log("take \(take.record.takeId) not fully recorded yet (history \(result.history.isDone), usage \(result.usage.isDone)); kept for the next launch")
      return false
    }
    // Both destinations are idempotent by take id, so a file whose flag
    // could not be saved is still safe to drop.
    if let spooled { pending.remove(spooled) }
    return true
  }
}

/// Holds the launch replay until the first settings are known (or failed to
/// load), so a replayed `keep_logs` take still gets its debug archive.
public final class ReplayGate: @unchecked Sendable {
  private let lock = NSLock()
  private var replay: (() -> Void)?
  private var settled = false
  private var ran = false

  public init() {}

  /// Runs `work` once settings have settled (now, if they already have).
  public func request(_ work: @escaping () -> Void) {
    lock.lock()
    replay = work
    let run = takeIfReady()
    lock.unlock()
    run?()
  }

  /// The first settings were adopted, or loading them failed.
  public func settle() {
    lock.lock()
    settled = true
    let run = takeIfReady()
    lock.unlock()
    run?()
  }

  private func takeIfReady() -> (() -> Void)? {
    guard settled, !ran, let work = replay else { return nil }
    ran = true
    replay = nil
    return work
  }
}
