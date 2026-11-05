import Foundation
import Testing

@testable import KhulumaCore

struct RecentDictationsTests {
  @Test func newestFirstSkippingBlankAndUnreadable() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-recent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func put(_ name: String, _ body: String, age: TimeInterval) throws {
      let url = dir.appendingPathComponent(name)
      try Data(body.utf8).write(to: url)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }
    try put("a.json", #"{"raw":"first"}"#, age: 400)
    try put("b.json", #"{"raw":"second"}"#, age: 300)
    try put("c.json", #"{"raw":"   "}"#, age: 200)
    try put("d.json", "not json", age: 100)
    try put("e.json", #"{"raw":"newest"}"#, age: 10)
    try put(".hidden.json", #"{"raw":"hidden"}"#, age: 1)
    try put("note.txt", #"{"raw":"text"}"#, age: 1)
    #expect(RecentDictations.raw(history: dir) == ["newest", "second", "first"])
    // The newest N files, then the skipping, as `history export N` did.
    #expect(RecentDictations.raw(history: dir, limit: 2) == ["newest"])
    #expect(RecentDictations.raw(history: dir.appendingPathComponent("missing")).isEmpty)
  }
}

struct VocabularyStoreFilesTests {
  @Test func savesWithPrivateFilesBackupsAndRefusals() throws {
    let root = try VocabularyParityTests.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VocabularyStore(root: root)
    var snapshot = try store.show()
    snapshot.document.words = [.init(heard: "a", write: "b")]
    let first = try store.save(snapshot)
    func mode(_ path: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1 }
    #expect(mode(root.appendingPathComponent("vocabulary.json").path) == 0o600)
    #expect(mode(root.appendingPathComponent(".vocabulary.lock").path) == 0o600)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("vocabulary-backups").path))
    let before = try Data(contentsOf: root.appendingPathComponent("vocabulary.json"))

    var next = first
    next.document.words = [.init(heard: "a", write: "c")]
    _ = try store.save(next)
    let backups = root.appendingPathComponent("vocabulary-backups")
    let names = try FileManager.default.contentsOfDirectory(atPath: backups.path)
    #expect(names.count == 1)
    #expect(try Data(contentsOf: backups.appendingPathComponent(names[0])) == before)
    #expect(mode(backups.path) == 0o700 && mode(backups.appendingPathComponent(names[0]).path) == 0o600)
    #expect(throws: (any Error).self) { try store.save(next) }  // `first`'s revision is stale now

    // Symlinks are refused.
    let target = root.appendingPathComponent("elsewhere.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.removeItem(at: root.appendingPathComponent("vocabulary.json"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("vocabulary.json"), withDestinationURL: target)
    #expect(throws: (any Error).self) { try store.show() }
  }
}

struct VocabularySyncFailureTests {
  struct SyncFailed: Error {}

  @Test func aFailedBackupSyncLeavesTheOldFileAndSaveRefused() throws {
    let root = try VocabularyParityTests.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var store = VocabularyStore(root: root)
    var snapshot = try store.show()
    snapshot.document.words = [.init(heard: "a", write: "b")]
    let saved = try store.save(snapshot)
    let sheet = root.appendingPathComponent("vocabulary.json")
    let before = try Data(contentsOf: sheet)

    store.syncDirectory = { _ in throw SyncFailed() }
    var next = saved
    next.document.words = [.init(heard: "a", write: "c")]
    #expect(throws: SyncFailed.self) { try store.save(next) }
    #expect(try Data(contentsOf: sheet) == before)
    #expect(try store.show().revision == saved.revision)
  }
}

struct UsageOverflowTests {
  private func report(_ json: String) throws -> UsageReport {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-ovf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("usage.json")
    try Data(json.utf8).write(to: url)
    return try UsageReportBuilder.report(url: url, today: CivilDate("2026-11-05")!, typingWPM: 1)
  }

  private func file(words: String = "10", count: String = "1", elapsed: String = "5", daily: String = "") -> String {
    #"{"schema_version":1,"delivered_dictations":{"count":\#(count),"by_flow":{"inline":1,"tmux":0}},"processed_words":\#(words),"recording_duration_ms":1,"full_elapsed_duration_ms":\#(elapsed)\#(daily)}"#
  }

  @Test func hugeValuesAreAnErrorNotACrash() throws {
    for json in [
      file(words: "9007199254740992000"), file(words: "18446744073709551615"), file(count: "9223372036854775807"),
      file(elapsed: "9007199254740993"), file(words: "200000000000000000000"), file(words: "1e300"),
      file(daily: #","daily":{"started_at":"2026-10-01T00:00:00Z","baseline_count":9223372036854775807,"days":{}}"#),
      file(daily: #","daily":{"started_at":"2026-10-01T00:00:00Z","baseline_count":0,"days":{"2026-10-01":{"count":9223372036854775807,"inline":1,"tmux":0,"words":1,"recording_ms":1,"full_elapsed_ms":1,"longest_recording_ms":1,"most_words":1}}}"#),
    ] {
      #expect(throws: UsageReportBuilder.Failure.self) { try report(json) }
    }
  }

  @Test func largestSupportedValuesStillBuild() throws {
    let max = "9007199254740992"
    // At 1 wpm the largest word count would not fit in milliseconds: that is the error case above.
    let r = try report(file(words: "100000000000", count: max, elapsed: max))
    #expect(r.words == 100_000_000_000 && r.fullElapsedMs == 9_007_199_254_740_992)
    // Two buckets at the limit: the sums neither trap nor wrap.
    let bucket = #"{"count":\#(max),"inline":1,"tmux":0,"words":1,"recording_ms":1,"full_elapsed_ms":1,"longest_recording_ms":1,"most_words":1}"#
    let daily = #","daily":{"started_at":"2026-10-01T00:00:00Z","baseline_count":\#(max),"days":{"2026-10-01":\#(bucket),"2026-10-02":\#(bucket)}}"#
    #expect(try report(file(count: max, daily: daily)).daily?.untrackedDeliveries == 0)
  }
}
