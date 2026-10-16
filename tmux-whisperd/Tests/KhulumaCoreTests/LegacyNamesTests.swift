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
    #expect(lines == ["moved Lowkey → \(support.appendingPathComponent("Khuluma").path); left in place: 2-same.json (name taken)"])
    #expect(read(support.appendingPathComponent("Khuluma/recovered/1-old.wav")) == "old only")
    #expect(read(support.appendingPathComponent("Khuluma/pending/2-same.json")) == "new clash")
    #expect(read(support.appendingPathComponent("Khuluma/pending/3-new.json")) == "new only")
    // The clashing file keeps its old place, so nothing is lost.
    #expect(read(support.appendingPathComponent("Lowkey/pending/2-same.json")) == "old clash")
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Lowkey/recovered").path))
  }

  @Test func aTimedOutTakesAudioAndSidecarStayTogether() throws {
    let (home, temp) = try scratch()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    try write("old audio", temp.appendingPathComponent("lowkey-timed-out/t1.wav"))
    try write("old info", temp.appendingPathComponent("lowkey-timed-out/t1.json"))
    try write("old audio 2", temp.appendingPathComponent("lowkey-timed-out/t2.wav"))
    try write("old info 2", temp.appendingPathComponent("lowkey-timed-out/t2.json"))
    // Only the sidecar's name is taken: the audio must not move without it.
    try write("new info", temp.appendingPathComponent("khuluma-timed-out/t1.json"))

    LegacyNames.migrate(home: home, temporary: temp)
    #expect(read(temp.appendingPathComponent("lowkey-timed-out/t1.wav")) == "old audio")
    #expect(read(temp.appendingPathComponent("lowkey-timed-out/t1.json")) == "old info")
    #expect(read(temp.appendingPathComponent("khuluma-timed-out/t1.json")) == "new info")
    #expect(!FileManager.default.fileExists(atPath: temp.appendingPathComponent("khuluma-timed-out/t1.wav").path))
    #expect(read(temp.appendingPathComponent("khuluma-timed-out/t2.wav")) == "old audio 2")
    #expect(read(temp.appendingPathComponent("khuluma-timed-out/t2.json")) == "old info 2")
  }

  @Test func symlinksAreNeverFollowed() throws {
    let (home, temp) = try scratch()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let elsewhere = home.deletingLastPathComponent().appendingPathComponent("elsewhere")
    try write("not ours", elsewhere.appendingPathComponent("pending/x.json"))
    let support = home.appendingPathComponent("Library/Application Support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Lowkey"), withDestinationURL: elsewhere)
    try write("mine", support.appendingPathComponent("Khuluma/pending/y.json"))

    let lines = LegacyNames.migrate(home: home, temporary: temp)
    #expect(lines == ["moved Lowkey → \(support.appendingPathComponent("Khuluma").path); left in place: Lowkey (symlink)"])
    #expect(read(elsewhere.appendingPathComponent("pending/x.json")) == "not ours")
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Khuluma/pending/x.json").path))
  }
}
