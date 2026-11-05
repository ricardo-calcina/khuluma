import Foundation
import Testing

@testable import KhulumaCore

struct PendingRecordsTests {
  private func makeDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory() + "khuluma-pending-\(UUID().uuidString)")
  }

  @Test func decodesBuild415BareRecord() throws {
    let dir = makeDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var bare = TakeRecord(takeId: "old415", status: "ok", delivered: true)
    bare.text = "hello"
    try JSONEncoder().encode(bare).write(to: dir.appendingPathComponent("1700000000000-old415.json"))
    let (records, quarantined) = PendingRecords(directory: dir).leftovers()
    #expect(quarantined.isEmpty)
    #expect(records.count == 1)
    #expect(records[0].take.record == bare)
    #expect(records[0].take.done == PendingTake.Done())
  }

  /// A bare record exactly as build 415 writes it (optional fields absent).
  static let build415JSON = """
    {"take_id":"t415-1","status":"ok","delivered":true,"raw_text":"um hello there","text":"Hello there.",\
    "record_ms":2100,"transcribe_ms":310,"clean_ms":4,"paste_ms":22,"total_ms":2450,"startup_ms":80,\
    "startup_source":"app:native","delivered_local_date":"2026-10-30"}
    """

  @Test func decodesFixedBuild415Fixture() throws {
    let dir = makeDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(Self.build415JSON.utf8).write(to: dir.appendingPathComponent("1761800000000-t415-1.json"))
    let (records, quarantined) = PendingRecords(directory: dir).leftovers()
    #expect(quarantined.isEmpty)
    let take = try #require(records.first?.take)
    #expect(take.record.takeId == "t415-1")
    #expect(take.record.text == "Hello there.")
    #expect(take.record.totalMs == 2450)
    #expect(take.record.deliveredLocalDate == "2026-10-30")
    #expect(take.done == PendingTake.Done())
  }

  @Test func looseExistingDirectoriesAreTightened() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    try FileManager.default.createDirectory(at: pending.quarantineDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    try Data("junk".utf8).write(to: dir.appendingPathComponent("1-bad.json"))
    _ = pending.leftovers()
    try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    for d in [dir, pending.quarantineDirectory] {
      let perms = try FileManager.default.attributesOfItem(atPath: d.path)[.posixPermissions] as? Int
      #expect(perms == 0o700)
    }
  }

  @Test func quarantineNeverOverwritesExistingName() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    try FileManager.default.createDirectory(at: pending.quarantineDirectory, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: pending.quarantineDirectory.appendingPathComponent("1-bad.json"))
    try Data("second".utf8).write(to: dir.appendingPathComponent("1-bad.json"))
    #expect(pending.leftovers().quarantined == ["1-bad.json"])
    let kept = try FileManager.default.contentsOfDirectory(atPath: pending.quarantineDirectory.path)
    #expect(kept.count == 2)
    #expect(try Data(contentsOf: pending.quarantineDirectory.appendingPathComponent("1-bad.json")) == Data("first".utf8))
  }

  @Test func concurrentMarkDoneKeepsEveryFlag() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    let url = try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    let all = PendingTake.Destination.allCases
    DispatchQueue.concurrentPerform(iterations: 30) { i in
      try? pending.markDone(url, all[i % all.count])
    }
    let take = try #require(pending.leftovers().records.first?.take)
    #expect(take.done == PendingTake.Done(history: true, bench: true, usage: true))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [url.lastPathComponent])
  }

  @Test func concurrentSavesAllLand() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    DispatchQueue.concurrentPerform(iterations: 40) { i in
      _ = try? pending.save(TakeRecord(takeId: "t\(i)", status: "ok", delivered: true))
    }
    let (records, quarantined) = pending.leftovers()
    #expect(quarantined.isEmpty)
    #expect(Set(records.map(\.take.record.takeId)).count == 40)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 40)
  }

  @Test func markDoneSurvivesReload() throws {
    let pending = PendingRecords(directory: makeDir())
    let url = try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    try pending.markDone(url, .history)
    try pending.markDone(url, .usage)
    let take = try #require(pending.leftovers().records.first?.take)
    #expect(take.done == PendingTake.Done(history: true, bench: false, usage: true))
    #expect(take.record.takeId == "a")
  }

  @Test func oldRecordIsStillReturned() throws {
    let pending = PendingRecords(directory: makeDir())
    let now = Date()
    try pending.save(TakeRecord(takeId: "old", status: "ok", delivered: true), at: now.addingTimeInterval(-8 * 24 * 3600))
    try pending.save(TakeRecord(takeId: "new", status: "ok", delivered: true), at: now)
    #expect(pending.leftovers(now: now).records.map(\.take.record.takeId) == ["old", "new"])
  }

  @Test func garbageGoesToQuarantine() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    try Data("junk".utf8).write(to: dir.appendingPathComponent("9999999999999-bad.json"))
    let (records, quarantined) = pending.leftovers()
    #expect(records.count == 1)
    #expect(quarantined == ["9999999999999-bad.json"])
    let moved = pending.quarantineDirectory.appendingPathComponent("9999999999999-bad.json")
    #expect(try Data(contentsOf: moved) == Data("junk".utf8))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("9999999999999-bad.json").path))
    let perms = try FileManager.default.attributesOfItem(atPath: pending.quarantineDirectory.path)[.posixPermissions] as? Int
    #expect(perms == 0o700)
  }

  @Test func staleTempGoesToQuarantineButFreshStays() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    let stale = dir.appendingPathComponent(".1-x.json.tmp")
    let fresh = dir.appendingPathComponent(".2-y.json.tmp")
    try Data("partial".utf8).write(to: stale)
    try Data("partial".utf8).write(to: fresh)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: stale.path)
    let (_, quarantined) = pending.leftovers(now: now)
    #expect(quarantined == [".1-x.json.tmp"])
    #expect(FileManager.default.fileExists(atPath: pending.quarantineDirectory.appendingPathComponent(".1-x.json.tmp").path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
  }

  @Test func saveIs0600AndLeavesNoTemp() throws {
    let dir = makeDir()
    let pending = PendingRecords(directory: dir)
    let url = try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    try pending.markDone(url, .bench)
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == [url.lastPathComponent])
  }

  @Test func removeDeletesRecord() throws {
    let pending = PendingRecords(directory: makeDir())
    let url = try pending.save(TakeRecord(takeId: "a", status: "ok", delivered: true))
    pending.remove(url)
    #expect(pending.leftovers().records.isEmpty)
  }
}
