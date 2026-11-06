import Foundation
import Testing
@testable import KhulumaCore

struct ModelRepairTests {
  @Test func aRecentlyChangedFolderIsBusy() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-repair-\(UUID().uuidString)")
    let nested = dir.appendingPathComponent("Encoder.mlmodelc")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = nested.appendingPathComponent("weights.partial")
    try Data([1]).write(to: file)
    let old = Date().addingTimeInterval(-3600)
    for url in [file, nested, dir] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }

    #expect(!ModelRepair.isBusy(dir.path))
    #expect(ModelRepair.isBusy(dir.path, now: old.addingTimeInterval(14 * 60)))
    #expect(!ModelRepair.isBusy(dir.path, now: old.addingTimeInterval(15 * 60)))

    // A nested file written just now makes the whole folder busy.
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    #expect(ModelRepair.isBusy(dir.path))
    #expect(ModelRepair.Busy().localizedDescription == "model folder busy, retrying later")
    #expect(!ModelRepair.isBusy(dir.appendingPathComponent("missing").path))
  }
}
