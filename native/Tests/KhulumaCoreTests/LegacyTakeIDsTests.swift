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
    try JSONSerialization.data(withJSONObject: ["old-1", "old-2"])
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

    // A broken list is ignored, not fatal.
    try Data("{".utf8).write(to: support.appendingPathComponent(LegacyImport.legacyTakeIDsName))
    #expect(!recorder.isRecorded(takeId: "old-1", pending: pending))
  }
}
