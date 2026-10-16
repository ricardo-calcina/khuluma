import Foundation
import Testing
@testable import KhulumaCore

/// Lowkey-era folders move to their Khuluma names at launch, without ever
/// overwriting anything.
struct LegacyNamesTests {
  private func scratch() throws -> (home: URL, temp: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home"), temp = root.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    return (home, temp)
  }

  private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

  @Test func nothingToMoveIsQuiet() throws {
    let (home, temp) = try scratch()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    #expect(LegacyNames.migrate(home: home, temporary: temp).isEmpty)
  }

  @Test func oldFoldersMoveWholeWhenTheNewOnesDontExist() throws {
    let (home, temp) = try scratch()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let support = home.appendingPathComponent("Library/Application Support")
    try write("log", home.appendingPathComponent("Library/Logs/Lowkey/app.log"))
    try write("record", support.appendingPathComponent("Lowkey/pending/1-a.json"))
    try write("audio", support.appendingPathComponent("Lowkey/recovered/1-b.wav"))
    try write("timed out", temp.appendingPathComponent("lowkey-timed-out/c.wav"))

    let lines = LegacyNames.migrate(home: home, temporary: temp)
    #expect(lines.count == 3 && lines.allSatisfy { $0.hasPrefix("moved ") && !$0.contains("left in place") })
    #expect(read(home.appendingPathComponent("Library/Logs/Khuluma/app.log")) == "log")
    #expect(read(support.appendingPathComponent("Khuluma/pending/1-a.json")) == "record")
    #expect(read(support.appendingPathComponent("Khuluma/recovered/1-b.wav")) == "audio")
    #expect(read(temp.appendingPathComponent("khuluma-timed-out/c.wav")) == "timed out")
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Lowkey").path))
    // Run again: nothing left to do.
    #expect(LegacyNames.migrate(home: home, temporary: temp).isEmpty)
  }

  @Test func bothExistingMergesFileByFileAndNeverOverwrites() throws {
    let (home, temp) = try scratch()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let support = home.appendingPathComponent("Library/Application Support")
    try write("old only", support.appendingPathComponent("Lowkey/recovered/1-old.wav"))
    try write("old clash", support.appendingPathComponent("Lowkey/pending/2-same.json"))
    try write("new clash", support.appendingPathComponent("Khuluma/pending/2-same.json"))
    try write("new only", support.appendingPathComponent("Khuluma/pending/3-new.json"))

    let lines = LegacyNames.migrate(home: home, temporary: temp)
    #expect(lines == ["moved Lowkey → \(support.appendingPathComponent("Khuluma").path); left in place (name taken): 2-same.json"])
    #expect(read(support.appendingPathComponent("Khuluma/recovered/1-old.wav")) == "old only")
    #expect(read(support.appendingPathComponent("Khuluma/pending/2-same.json")) == "new clash")
    #expect(read(support.appendingPathComponent("Khuluma/pending/3-new.json")) == "new only")
    // The clashing file keeps its old place, so nothing is lost.
    #expect(read(support.appendingPathComponent("Lowkey/pending/2-same.json")) == "old clash")
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Lowkey/recovered").path))
  }
}
