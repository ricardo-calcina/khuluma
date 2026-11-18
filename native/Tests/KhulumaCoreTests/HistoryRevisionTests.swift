import Foundation
import Testing
@testable import KhulumaCore

/// Transcribe again's history rewrite, and the retention forever/off rules.
struct HistoryRevisionTests {
  private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-revision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("history"), withIntermediateDirectories: true)
    return dir
  }

  @Test func versionsNewestFirstCappedAtFive() {
    var object: [String: Any] = ["raw": "r0", "processed": "p0", "take_id": "t", "app": "Notes"]
    for n in 1...7 {
      object = HistoryRevision.revised(object, raw: "r\(n)", processed: "p\(n)", replacedAt: "at\(n)")
    }
    #expect(object["raw"] as? String == "r7")
    #expect(object["processed"] as? String == "p7")
    #expect(object["take_id"] as? String == "t")
    let versions = object["versions"] as? [[String: Any]] ?? []
    #expect(versions.count == 5)
    #expect(versions.map { $0["raw"] as? String } == ["r6", "r5", "r4", "r3", "r2"])
    #expect(versions.first?["processed"] as? String == "p6")
    #expect(versions.first?["replaced_at"] as? String == "at7")
  }

  @Test func replaceKeepsOtherKeysMtimeAndStaysReadable() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history/2026-11-09T10-00-00.json")
    let json: [String: Any] = ["timestamp": "2026-11-09T10:00:00Z", "app": "Notes", "raw": "old raw",
                               "processed": "Old.", "take_id": "abc", "metrics": ["record_ms": 900]]
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

    try HistoryRevision.replace(at: url, raw: "new raw", processed: "New.")

    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    #expect(object["processed"] as? String == "New.")
    #expect(object["take_id"] as? String == "abc")
    #expect((object["versions"] as? [[String: Any]])?.first?["processed"] as? String == "Old.")
    let mtime = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(mtime == old)
    let items = DictationHistory.load(directory: root.appendingPathComponent("history"))
    #expect(items.map(\.text) == ["New."])
    #expect(items.first?.raw == "new raw")
    #expect(items.first?.recordMs == 900)
    #expect(HistoryWriter(directory: root.appendingPathComponent("history")).entryURL(takeId: "abc") != nil)
  }

  @Test func failedReplaceLeavesEntryUntouched() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history/a.json")
    let original = Data("[1, 2]".utf8)
    try original.write(to: url)
    #expect(throws: (any Error).self) { try HistoryRevision.replace(at: url, raw: "x", processed: "y") }
    #expect(try Data(contentsOf: url) == original)
    #expect(throws: (any Error).self) {
      try HistoryRevision.replace(at: root.appendingPathComponent("history/missing.json"), raw: "x", processed: "y")
    }
  }

  @Test func keptWAVOnlyWhenItExists() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history")
    let prefix = history.appendingPathComponent("take").path
    for (name, wav) in [("a.json", true), ("b.json", false)] {
      let json: [String: Any] = ["timestamp": "2026-11-09T10:00:00Z", "raw": "um hi", "processed": "Hi.",
                                 "audio": ["debug_archive_prefix": prefix + name]]
      try JSONSerialization.data(withJSONObject: json).write(to: history.appendingPathComponent(name))
      if wav { try Data().write(to: URL(fileURLWithPath: prefix + name + ".wav")) }
    }
    let items = DictationHistory.load(directory: history)
    #expect(items.first { $0.id == "a.json" }?.keptWAV != nil)
    #expect(items.first { $0.id == "b.json" }?.keptWAV == nil)
    #expect(items.allSatisfy { $0.rawDiffers })
  }

  @Test func zeroHistoryRetentionKeepsForever() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history/old.json")
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
    let trashed = Box()
    let writer = HistoryWriter(directory: root.appendingPathComponent("history"), retentionDays: 0,
                               trash: { trashed.append($0) })
    try writer.prune()
    #expect(trashed.urls.isEmpty)
    var week = writer; week.retentionDays = 7
    try week.prune()
    #expect(trashed.urls.map(\.lastPathComponent) == ["old.json"])
  }

  @Test func audioOffWritesMetaButNoWAV() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("take.wav")
    try Data("RIFF".utf8).write(to: source)
    let dir = root.appendingPathComponent("history/inline-debug")
    let off = DebugArchive(directory: dir, audioRetentionDays: 0)
    #expect(off.archive(wav: source, record: TakeRecord(takeId: "t1", status: "ok", delivered: true), captureGapMs: nil) == nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains { $0.hasSuffix(".meta") })
    #expect(!names.contains { $0.hasSuffix(".wav") })
    let on = DebugArchive(directory: dir, audioRetentionDays: 2)
    #expect(on.archive(wav: source, record: TakeRecord(takeId: "t2", status: "ok", delivered: true), captureGapMs: nil) != nil)
  }

  @Test func metaWithoutWAVIsNotReusedAsTheArchive() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("take.wav")
    try Data("RIFF".utf8).write(to: source)
    let dir = root.appendingPathComponent("history/inline-debug")
    let record = TakeRecord(takeId: "t1", status: "ok", delivered: true)
    #expect(DebugArchive(directory: dir, audioRetentionDays: 0).archive(wav: source, record: record, captureGapMs: nil) == nil)
    let saved = DebugArchive(directory: dir, audioRetentionDays: 2).archive(wav: source, record: record, captureGapMs: nil)
    #expect(saved != nil)
    #expect(FileManager.default.fileExists(atPath: (saved?.prefix ?? "") + ".wav"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".meta") }.count == 1)
  }

  @Test func eachTakeExpiresArchivedAudioEvenWithoutAWAV() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("history/inline-debug")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = dir.appendingPathComponent("old-t.wav")
    try Data().write(to: old)
    let recorder = TakeRecorder(root: root, settings: .init(historyRetentionDays: 7, audioRetentionDays: 0, keepLogs: false))
    _ = recorder.record(TakeRecord(takeId: "x", status: "no_speech", delivered: false))
    #expect(!FileManager.default.fileExists(atPath: old.path))
  }

  @Test func stagedRevisionLeavesNoVisibleFile() throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history")
    let url = history.appendingPathComponent("a.json")
    try JSONSerialization.data(withJSONObject: ["raw": "a", "processed": "A."]).write(to: url)
    // A crash leftover from staging is never listed.
    try Data("{\"raw\": \"x\"}".utf8).write(to: history.appendingPathComponent(".a.json.rev-abc123"))
    try HistoryRevision.replace(at: url, raw: "b", processed: "B.")
    #expect(DictationHistory.load(directory: history).map(\.text) == ["B."])
    #expect(RecentDictations.raw(history: history).count <= 1)
  }

  @Test func audioClampedToHistory() throws {
    #expect(TakeRecorder.Settings.from(nil, historyRetentionDays: 1, audioRetentionDays: 7, environment: [:]).audioRetentionDays == 1)
    #expect(TakeRecorder.Settings.from(nil, historyRetentionDays: 0, audioRetentionDays: 7, environment: [:]).audioRetentionDays == 7)
    #expect(HistoryRetention.clampedAudio(7, history: 1) == 1)
    #expect(HistoryRetention.clampedAudio(7, history: 0) == 7)
    #expect(HistoryRetention.clampedAudio(-3, history: 7) == 0)
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(folder: root.appendingPathComponent("app"))
    var saved = try store.set("history.audio_retention_days", value: "7")
    #expect(saved.history.audioRetentionDays == 7)
    saved = try store.set("history.retention_days", value: "1")
    #expect(saved.history.retentionDays == 1 && saved.history.audioRetentionDays == 1)
    saved = try store.set("history.audio_retention_days", value: "2")
    #expect(saved.history.audioRetentionDays == 1)
    saved = try store.set("history.retention_days", value: "0")
    saved = try store.set("history.audio_retention_days", value: "0")
    #expect(saved.history.retentionDays == 0 && saved.history.audioRetentionDays == 0)
    #expect(store.load().settings.history.retentionDays == 0)
    #expect(throws: (any Error).self) { try store.set("history.retention_days", value: "-1") }
  }
}

private final class Box: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [URL] = []
  var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
  func append(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
}
