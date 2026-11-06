import Foundation
import Testing
@testable import KhulumaCore

/// Take ids the CLI saved before the import count as recorded, so a
/// build-415 pending or recovered take replayed afterwards isn't saved twice.
struct LegacyTakeIDsTests {
  @Test func importedIdsAreRecordedAndNeverSavedAgain() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("legacy-ids-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["history": ["old-1", "old-2"], "usage": ["old-2"]])
      .write(to: support.appendingPathComponent(LegacyImport.legacyTakeIDsName))
    let recorder = TakeRecorder(root: support, settings: .init(keepLogs: false),
                                now: { Date(timeIntervalSince1970: 1_793_870_042) },
                                timeZone: TimeZone(identifier: "Europe/London")!, trash: { _ in }, temporaryRoots: [])
    let pending = PendingRecords(directory: root.appendingPathComponent("pending", isDirectory: true))
    #expect(recorder.isRecorded(takeId: "old-1", pending: pending))
    #expect(!recorder.isRecorded(takeId: "new-1", pending: pending))

    var take = TakeRecord(takeId: "old-2", status: "ok", delivered: true)
    take.text = "Hello there."
    take.recordMs = 1000
    take.deliveredLocalDate = "2026-11-05"
    let result = recorder.record(take)
    #expect(result.history == .alreadyThere && result.usage == .alreadyThere)
    #expect(!FileManager.default.fileExists(atPath: recorder.usageURL.path))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: recorder.historyDirectory.path))?.isEmpty ?? true)

    // Partial: the CLI counted nothing and its history save failed after the
    // bench mark (bench-only id): nothing is proven, so history is written.
    var partial = TakeRecord(takeId: "bench-only", status: "ok", delivered: true)
    partial.text = "Keep me."
    partial.recordMs = 1000
    partial.deliveredLocalDate = "2026-11-05"
    #expect(!recorder.isRecorded(takeId: "bench-only", pending: pending))
    let saved = recorder.record(partial)
    #expect(saved.history == .written && saved.usage == .written)
    #expect(recorder.isRecorded(takeId: "bench-only", pending: pending))

    // History proven, usage not: only usage is redone.
    var halfway = TakeRecord(takeId: "old-1", status: "ok", delivered: true)
    halfway.text = "Counted later."
    halfway.recordMs = 1000
    halfway.deliveredLocalDate = "2026-11-05"
    let half = recorder.record(halfway)
    #expect(half.history == .alreadyThere && half.usage == .written)

    // The old union array proves nothing and is ignored.
    try JSONSerialization.data(withJSONObject: ["old-1"]).write(to: support.appendingPathComponent(LegacyImport.legacyTakeIDsName))
    #expect(!recorder.isRecorded(takeId: "old-1", pending: pending))

    // A broken list is ignored, not fatal.
    try Data("{".utf8).write(to: support.appendingPathComponent(LegacyImport.legacyTakeIDsName))
    #expect(!recorder.isRecorded(takeId: "old-1", pending: pending))
  }
}
