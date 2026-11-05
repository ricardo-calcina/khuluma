import Darwin
import Foundation
import Testing

@testable import KhulumaCore

/// The app's own history and usage writers. Every test uses a fresh temp
/// root; nothing resolves the real support folder or the Trash.
struct StorageTests {
  static let fixedNow = Date(timeIntervalSince1970: 1_793_870_042)  // 2026-11-05T09:14:02Z
  static let london = TimeZone(identifier: "Europe/London")!

  private func makeRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-storage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func recorder(_ root: URL, keepLogs: Bool = false, now: Date = fixedNow) -> TakeRecorder {
    let trashDir = root.appendingPathComponent("test-trash")
    return TakeRecorder(
      root: root.appendingPathComponent("support"), settings: .init(keepLogs: keepLogs),
      now: { now }, timeZone: Self.london,
      trash: { url in
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
      },
      temporaryRoots: [root.appendingPathComponent("tmp")])
  }

  private func take(_ id: String, status: String = "ok", delivered: Bool = true, text: String = "Héllo, wörld!") -> TakeRecord {
    var r = TakeRecord(takeId: id, status: status, delivered: delivered)
    r.rawText = "héllo wörld"
    r.text = text
    r.app = "TextEdit"
    r.model = "parakeet-v3"
    r.recordMs = 1000
    r.transcribeMs = 20
    r.totalMs = 1200
    r.startedAtMs = 1000
    r.deliveredAtMs = 2500
    return r
  }

  private func usage(_ rec: TakeRecorder) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rec.usageURL)) as? [String: Any])
  }

  private func historyFiles(_ rec: TakeRecorder) -> [URL] { rec.history.entries() }

  // MARK: - Word counting (expected values computed once with python3:
  // len(re.findall(r"\b\w+\b", text, flags=re.UNICODE)))

  @Test(arguments: [
    ("h\u{e9}llo w\u{f6}rld", 2), ("H\u{e9}llo, w\u{f6}rld!", 2), ("don't stop", 3), ("it\u{2019}s 3.14 or 1,000", 7),
    ("snake_case __init__ _", 3), ("e\u{301}te\u{301} caf\u{e9}", 3), ("na\u{ef}ve fa\u{e7}ade", 2),
    ("emoji \u{1F389} party \u{1F44D}\u{1F3FD} ok", 3), ("\u{4e2d}\u{6587}\u{5b57}\u{7b26} \u{548c} \u{65e5}\u{672c}\u{8a9e}", 3),
    ("state-of-the-art re-run", 6), ("x\u{b2} \u{bd} \u{216b} \u{663}\u{664}\u{665}", 4), ("tab\tnew\nline", 3),
    ("  ", 0), ("", 0), ("\u{dc}n\u{ef}c\u{f6}d\u{e9}\u{2014}dash\u{2013}en", 3), ("\u{fb01}ne ligature", 2),
    ("Hello\u{200d}world", 2), ("1st 2nd #3 @user email@example.com", 7),
  ])
  func wordCountMatchesPython(text: String, expected: Int) {
    #expect(WordCount.count(text) == expected)
  }

  // MARK: - Usage

  @Test func usageMatchesTheCLIShape() throws {
    let rec = recorder(try makeRoot())
    let result = rec.record(take("t1"))
    #expect(result == .init(history: .written, usage: .written))
    let u = try usage(rec)
    // What `inline record` wrote for the same take (v0.11, TZ Europe/London).
    #expect(u["schema_version"] as? Int == 1)
    #expect(u["tracking_started_at"] as? String == "2026-11-05T09:14:02Z")
    #expect(u["processed_words"] as? Int == 2)
    #expect(u["recording_duration_ms"] as? Int == 1000)
    #expect(u["full_elapsed_duration_ms"] as? Int == 1500)
    let d = try #require(u["delivered_dictations"] as? [String: Any])
    #expect(d["count"] as? Int == 1)
    #expect(d["by_flow"] as? [String: Int] == ["inline": 1, "tmux": 0])
    let daily = try #require(u["daily"] as? [String: Any])
    #expect(daily["baseline_count"] as? Int == 0)
    #expect(daily["started_at"] as? String == "2026-11-05T09:14:02Z")
    #expect((daily["days"] as? [String: [String: Int]])?["2026-11-05"] == [
      "count": 1, "inline": 1, "tmux": 0, "words": 2, "recording_ms": 1000, "full_elapsed_ms": 1500,
      "longest_recording_ms": 1000, "most_words": 2,
    ])
    #expect(u["recent_take_ids"] as? [String: String] == ["t1": "2026-11-05"])
    #expect(Set(u.keys) == ["schema_version", "tracking_started_at", "delivered_dictations", "processed_words",
                            "recording_duration_ms", "full_elapsed_duration_ms", "daily", "recent_take_ids"])
  }

  @Test func usageKeepsUnknownKeysAndSetsBaseline() throws {
    let rec = recorder(try makeRoot())
    try FileManager.default.createDirectory(at: rec.root, withIntermediateDirectories: true)
    try Data("""
    {"schema_version": 1, "tracking_started_at": "2026-01-01T00:00:00Z", "extra": {"keep": true},
     "delivered_dictations": {"count": 5, "by_flow": {"inline": 4, "tmux": 1}},
     "processed_words": 10, "recording_duration_ms": 100, "full_elapsed_duration_ms": 200,
     "recent_take_ids": {"old": "2026-10-01", "recent": "2026-11-01", "junk": 3}}
    """.utf8).write(to: rec.usageURL)
    var r = take("t2", text: "one two three")
    r.deliveredLocalDate = "2026-11-04"
    #expect(rec.record(r).usage == .written)
    let u = try usage(rec)
    #expect((u["extra"] as? [String: Bool]) == ["keep": true])
    #expect((u["delivered_dictations"] as? [String: Any])?["count"] as? Int == 6)
    #expect(u["processed_words"] as? Int == 13)
    let daily = try #require(u["daily"] as? [String: Any])
    #expect(daily["baseline_count"] as? Int == 5)
    #expect((daily["days"] as? [String: Any])?["2026-11-04"] != nil)
    // 14-day pruning; the replayed take counts on its delivery date.
    #expect(u["recent_take_ids"] as? [String: String] == ["recent": "2026-11-01", "t2": "2026-11-04"])
  }

  @Test func usageRefusesUnreadableOrOtherSchema() throws {
    let rec = recorder(try makeRoot())
    try FileManager.default.createDirectory(at: rec.root, withIntermediateDirectories: true)
    for body in ["not json", #"{"schema_version": 2, "delivered_dictations": {"by_flow": {}}}"#] {
      try Data(body.utf8).write(to: rec.usageURL)
      guard case .failed = rec.record(take(UUID().uuidString)).usage else { Issue.record("wrote over \(body)"); continue }
      #expect(try String(contentsOf: rec.usageURL, encoding: .utf8) == body)
    }
  }

  // MARK: - Rules and idempotency

  @Test func sameTakeTwiceIsOneOfEach() throws {
    let rec = recorder(try makeRoot())
    #expect(rec.record(take("dup")) == .init(history: .written, usage: .written))
    #expect(rec.record(take("dup")) == .init(history: .alreadyThere, usage: .alreadyThere))
    #expect(historyFiles(rec).count == 1)
    #expect((try usage(rec)["delivered_dictations"] as? [String: Any])?["count"] as? Int == 1)
    let entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: historyFiles(rec)[0])) as? [String: Any])
    #expect(entry["take_id"] as? String == "dup")
    #expect(entry["app"] as? String == "TextEdit")
    #expect(entry["raw"] as? String == "héllo wörld")
    #expect(entry["processed"] as? String == "Héllo, wörld!")
    #expect(entry["timestamp"] as? String == "2026-11-05T09:14:02Z")
    #expect(entry["metrics"] as? [String: Int] == ["record_ms": 1000, "transcribe_ms": 20, "clean_ms": 0, "paste_ms": 0, "total_ms": 1200])
    #expect(entry["writer"] == nil)
    #expect(historyFiles(rec)[0].lastPathComponent == "2026-11-05T09-14-02.json")
  }

  @Test func sameSecondTakesGetSuffixes() throws {
    let rec = recorder(try makeRoot())
    for id in ["a", "b", "c"] { _ = rec.record(take(id)) }
    #expect(historyFiles(rec).map(\.lastPathComponent) == ["2026-11-05T09-14-02.json", "2026-11-05T09-14-02_2.json", "2026-11-05T09-14-02_3.json"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: rec.historyDirectory.path).allSatisfy { !$0.hasPrefix(".history.tmp") })
  }

  @Test func statusRules() throws {
    let rec = recorder(try makeRoot())
    #expect(rec.record(take("rec", status: "recovered", delivered: false)) == .init(history: .written, usage: .notNeeded))
    #expect(rec.record(take("pf", status: "paste_failed", delivered: false)) == .init(history: .notNeeded, usage: .notNeeded))
    #expect(rec.record(take("nd", status: "ok", delivered: false)) == .init(history: .notNeeded, usage: .notNeeded))
    var usageOnly = take("uo")
    usageOnly.usageOnly = true
    #expect(rec.record(usageOnly) == .init(history: .notNeeded, usage: .written))
    var empty = take("noapp")
    empty.app = nil
    _ = rec.record(empty)
    #expect(historyFiles(rec).count == 2)
    let apps = try historyFiles(rec).map { (try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])?["app"] as? String }
    #expect(apps.contains("current"))
    #expect((try usage(rec)["delivered_dictations"] as? [String: Any])?["count"] as? Int == 2)
  }

  /// History fails after usage was written; the replay with the spool's
  /// flags writes only history, and a replay without flags still counts once.
  @Test func failureBetweenDestinationsThenReplay() throws {
    let rec = recorder(try makeRoot())
    try FileManager.default.createDirectory(at: rec.root, withIntermediateDirectories: true)
    try Data().write(to: rec.historyDirectory)  // a file where the folder goes
    let pending = PendingRecords(directory: rec.root.deletingLastPathComponent().appendingPathComponent("pending"))
    let url = try pending.save(take("crash"))
    let first = rec.record(take("crash"))
    #expect(first.usage == .written)
    guard case .failed = first.history else { Issue.record("history should fail"); return }
    try pending.markDone(url, .usage)

    try FileManager.default.removeItem(at: rec.historyDirectory)
    let spooled = try #require(pending.leftovers().records.first?.take)
    #expect(spooled.done.usage && !spooled.done.history)
    #expect(rec.record(spooled.record, done: spooled.done) == .init(history: .written, usage: .alreadyThere))
    #expect(rec.record(take("crash")) == .init(history: .alreadyThere, usage: .alreadyThere))
    #expect((try usage(rec)["delivered_dictations"] as? [String: Any])?["count"] as? Int == 1)
    #expect(historyFiles(rec).count == 1)
  }

  @Test func lockTimeoutLeavesTheTakePending() throws {
    var rec = recorder(try makeRoot())
    rec.lockTimeout = 0.2
    try FileManager.default.createDirectory(at: rec.root, withIntermediateDirectories: true)
    let fd = open(rec.lockURL.path, O_RDWR | O_CREAT, 0o600)
    #expect(flock(fd, LOCK_EX) == 0)
    let blocked = rec.record(take("locked"))
    #expect(!blocked.usage.isDone && !blocked.history.isDone)
    #expect(!FileManager.default.fileExists(atPath: rec.usageURL.path))
    close(fd)
    #expect(rec.record(take("locked")) == .init(history: .written, usage: .written))
  }

  // MARK: - Retention and the debug archive

  @Test func expiredHistoryGoesToTheTrash() throws {
    let root = try makeRoot()
    let rec = recorder(root)
    try FileManager.default.createDirectory(at: rec.historyDirectory, withIntermediateDirectories: true)
    let old = rec.historyDirectory.appendingPathComponent("2026-10-20T10-00-00.json")
    let edge = rec.historyDirectory.appendingPathComponent("2026-10-28T10-00-00.json")
    for (url, days) in [(old, 8.1), (edge, 7.9)] {
      try Data("{}".utf8).write(to: url)
      try FileManager.default.setAttributes([.modificationDate: Self.fixedNow.addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
    }
    _ = rec.record(take("new"))
    let names = Set(historyFiles(rec).map(\.lastPathComponent))
    #expect(!names.contains(old.lastPathComponent))
    #expect(names.contains(edge.lastPathComponent))  // 7 whole days: kept (find -mtime +7)
    let trashed = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("test-trash").path)
    #expect(trashed.count == 1 && trashed[0].hasSuffix(old.lastPathComponent))
  }

  private func writeWAV(_ url: URL, bytes: Int = 3200) throws {
    var d = Data("RIFF".utf8)
    func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
    u32(36 + bytes); d.append(contentsOf: Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    d.append(contentsOf: Data("data".utf8)); u32(bytes); d.append(Data(count: bytes))
    try d.write(to: url)
  }

  @Test func keepLogsArchivesAndExpiresAudio() throws {
    let root = try makeRoot()
    let rec = recorder(root, keepLogs: true)
    let tmp = root.appendingPathComponent("tmp")
    let debug = rec.historyDirectory.appendingPathComponent("inline-debug")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: debug, withIntermediateDirectories: true)
    let stale = debug.appendingPathComponent("2026-11-03T08-00-00-old.wav")
    let fresh = debug.appendingPathComponent("2026-11-03T10-00-00-young.wav")
    for (url, hours) in [(stale, 49.0), (fresh, 47.0)] {
      try writeWAV(url)
      try FileManager.default.setAttributes([.modificationDate: Self.fixedNow.addingTimeInterval(-hours * 3600)], ofItemAtPath: url.path)
    }
    let working = tmp.appendingPathComponent("khuluma-take-1.wav")
    try writeWAV(working)
    var r = take("arch")
    r.wavPath = working.path
    r.captureWavMs = 1100
    r.captureWavBytes = 35244
    #expect(rec.record(r) == .init(history: .written, usage: .written))

    #expect(!FileManager.default.fileExists(atPath: working.path))  // released after history
    #expect(!FileManager.default.fileExists(atPath: stale.path))    // 48 h expiry
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    let prefix = debug.appendingPathComponent("2026-11-05T09-14-02-arch").path
    #expect(FileManager.default.fileExists(atPath: prefix + ".wav"))
    let meta = try String(contentsOfFile: prefix + ".meta", encoding: .utf8)
    #expect(meta.contains("session_id=arch\n") && meta.contains("archive_wav_ms=100\n"))
    let entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: historyFiles(rec)[0])) as? [String: Any])
    let audio = try #require(entry["audio"] as? [String: Any])
    #expect(audio["capture_wav_ms"] as? Int == 1100)
    #expect(audio["capture_gap_to_record_ms"] as? Int == 100)
    #expect(audio["archive_wav_ms"] as? Int == 100)
    #expect(audio["archive_wav_bytes"] as? Int == 3244)
    #expect(audio["wav_retention_days"] as? Int == 2)
    #expect(audio["debug_archive_prefix"] as? String == prefix)
  }

  @Test func workingAudioOutsideTheTempRootsIsLeftAlone() throws {
    let root = try makeRoot()
    let elsewhere = root.appendingPathComponent("khuluma-take-2.wav")
    try writeWAV(elsewhere)
    #expect(!DebugArchive.deleteWorkingAudio(elsewhere.path, roots: [root.appendingPathComponent("tmp")]))
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    let notOurs = root.appendingPathComponent("notes.wav")
    try writeWAV(notOurs)
    #expect(!DebugArchive.deleteWorkingAudio(notOurs.path, roots: [root]))
  }

  // MARK: - Review fixes: durability, protected ids, replay ordering

  @Test func directorySyncFailureKeepsTheFlagsFalse() throws {
    let root = try makeRoot()
    var rec = recorder(root)
    rec.syncDirectory = { _ in throw DataFiles.Failure("injected fsync failure") }
    let pending = PendingRecords(directory: root.appendingPathComponent("pending"))
    let url = try pending.save(take("nosync"))
    #expect(!rec.apply(PendingTake(record: take("nosync")), spooled: url, pending: pending))
    let spooled = try #require(pending.leftovers().records.first?.take)
    #expect(spooled.done == PendingTake.Done())
    // Once syncing works, the replay finds both writes by take id.
    rec.syncDirectory = DataFiles.syncDirectory
    #expect(rec.apply(spooled, spooled: url, pending: pending))
    #expect(pending.leftovers().records.isEmpty)
    #expect((try usage(rec)["delivered_dictations"] as? [String: Any])?["count"] as? Int == 1)
    #expect(historyFiles(rec).count == 1)
  }

  /// Crash after the usage write, before the flag: weeks later the take's id
  /// would be pruned, but it is still spooled, so it stays and the replay
  /// counts once. Its history entry is spared from retention too.
  @Test func spooledTakesSurvivePruningAndCountOnce() throws {
    let root = try makeRoot()
    let pending = PendingRecords(directory: root.appendingPathComponent("pending"))
    let early = recorder(root)
    _ = try pending.save(take("crash"))
    #expect(early.record(take("crash")) == .init(history: .written, usage: .written))  // no flags saved
    let entry = try #require(historyFiles(early).first)
    try FileManager.default.setAttributes([.modificationDate: Self.fixedNow], ofItemAtPath: entry.path)

    let later = recorder(root, now: Self.fixedNow.addingTimeInterval(20 * 86400))
    let other = try pending.save(take("later"))
    #expect(later.apply(PendingTake(record: take("later")), spooled: other, pending: pending))
    let ids = try #require(try usage(later)["recent_take_ids"] as? [String: String])
    #expect(ids["crash"] == "2026-11-05")
    #expect(historyFiles(later).contains(entry))

    let (left, _) = pending.leftovers()
    let crashed = try #require(left.first { $0.take.record.takeId == "crash" })
    #expect(later.apply(crashed.take, spooled: crashed.url, pending: pending))
    #expect((try usage(later)["delivered_dictations"] as? [String: Any])?["count"] as? Int == 2)
    #expect(historyFiles(later).count == 2)
    #expect(pending.leftovers().records.isEmpty)
  }

  /// Python sorts the ids by date only, stably in insertion order (the file's,
  /// then the new id): at the cap the first-listed same-day id goes, and the
  /// new one always stays.
  @Test func takeIdCapMatchesPythonsStableSort() throws {
    let rec = recorder(try makeRoot())
    try FileManager.default.createDirectory(at: rec.root, withIntermediateDirectories: true)
    let listed = (0..<UsageLedger.takeIdMax).map { "z\(UsageLedger.takeIdMax - $0)" }  // not alphabetical
    let ids = listed.map { "\"\($0)\": \"2026-11-05\"" }.joined(separator: ", ")
    try Data("""
    {"schema_version": 1, "delivered_dictations": {"count": 0, "by_flow": {"inline": 0, "tmux": 0}},
     "recent_take_ids": {\(ids)}}
    """.utf8).write(to: rec.usageURL)
    #expect(rec.record(take("a-new")).usage == .written)
    let kept = try #require(try usage(rec)["recent_take_ids"] as? [String: String])
    #expect(kept.count == UsageLedger.takeIdMax)
    #expect(kept["a-new"] != nil)
    #expect(kept[listed[0]] == nil)
    #expect(kept[listed[1]] != nil && kept[listed.last!] != nil)
  }

  @Test func replayWaitsForTheFirstSettings() {
    let gate = ReplayGate()
    let runs = Counter()
    gate.request { runs.add() }
    #expect(runs.value == 0)
    gate.settle()
    #expect(runs.value == 1)
    gate.settle()
    #expect(runs.value == 1)

    let ready = ReplayGate()
    ready.settle()
    ready.request { runs.add() }
    #expect(runs.value == 2)
  }

  @Test func retentionIsAPlainInput() {
    let s = TakeRecorder.Settings.from(nil, historyRetentionDays: 30, audioRetentionDays: 5, environment: [:])
    #expect(s == .init(historyRetentionDays: 30, audioRetentionDays: 5, keepLogs: false))
    #expect(TakeRecorder.Settings.from(nil, environment: ["KHULUMA_KEEP_LOGS": "1"]).keepLogs)
  }

  // MARK: - Two writers

  /// Two app copies (separate recorders and lock descriptors) record 20 takes
  /// each at once, then replay each other's: exact totals, no duplicates.
  @Test func twoWritersRaceOnTheDataLock() throws {
    let root = try makeRoot()
    let a = recorder(root), b = recorder(root)
    let failures = Counter()
    DispatchQueue.concurrentPerform(iterations: 2) { side in
      let rec = side == 0 ? a : b
      for i in 0..<20 {
        if !rec.record(take("w\(side)-\(i)", text: "one two \(i)")).complete { failures.add() }
      }
      for i in 0..<20 {
        if !rec.record(take("w\(1 - side)-\(i)", text: "one two \(i)")).complete { failures.add() }
      }
    }
    #expect(failures.value == 0)
    let u = try usage(a)
    #expect((u["delivered_dictations"] as? [String: Any])?["count"] as? Int == 40)
    #expect(u["processed_words"] as? Int == 120)
    #expect((u["recent_take_ids"] as? [String: String])?.count == 40)
    let days = (u["daily"] as? [String: Any])?["days"] as? [String: [String: Int]]
    #expect(days?["2026-11-05"]?["count"] == 40)
    let ids = try a.history.entries().map { (try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])?["take_id"] as? String }
    #expect(ids.count == 40 && Set(ids).count == 40)
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func add() { lock.lock(); n += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
