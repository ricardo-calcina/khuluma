import Foundation
import Testing
@testable import KhulumaCore

/// LiveSpool: the on-disk PCM the take leaves behind while recording.
struct LiveSpoolTests {
  private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-spool-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// The PCM16 bytes a recovered WAV wraps (after its 44-byte header).
  private func wavPCM(_ url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    #expect(data.count > 44)
    return Array(data[44...]).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
  }

  @Test func appendedPiecesRecoverAsOneWAV() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spool = LiveSpool(directory: dir.appendingPathComponent("live"))
    let recovered = RecoveredTakes(directory: dir.appendingPathComponent("recovered"))
    let samples: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6]
    let writer = try spool.open(takeId: "abc123")
    writer.append(Array(samples[..<3]))
    writer.append(Array(samples[3...]))
    writer.close()
    #expect(spool.recoverAll(into: recovered) == 1)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: spool.directory.path)) == [])
    let wavs = try FileManager.default.contentsOfDirectory(atPath: recovered.directory.path)
    #expect(wavs.count == 1 && wavs[0].hasSuffix("-abc123.wav"))
    #expect(try wavPCM(recovered.directory.appendingPathComponent(wavs[0])) == WAVEncoder.pcm16(samples))
  }

  @Test func anEmptySpoolIsJustDeleted() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spool = LiveSpool(directory: dir.appendingPathComponent("live"))
    let recovered = RecoveredTakes(directory: dir.appendingPathComponent("recovered"))
    let writer = try spool.open(takeId: "empty1")
    writer.close()
    #expect(spool.recoverAll(into: recovered) == 0)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: spool.directory.path)) == [])
  }

  @Test func removeDeletesTheFile() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spool = LiveSpool(directory: dir.appendingPathComponent("live"))
    let writer = try spool.open(takeId: "gone11")
    writer.append([0.5])
    writer.remove()
    #expect(!FileManager.default.fileExists(atPath: writer.url.path))
  }

  @Test func dirAndFilePermissionsArePrivate() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spool = LiveSpool(directory: dir.appendingPathComponent("live"))
    let writer = try spool.open(takeId: "perm22")
    writer.close()
    let attrs = try FileManager.default.attributesOfItem(atPath: writer.url.path)
    #expect(attrs[.posixPermissions] as? Int == 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: spool.directory.path)
    #expect(dirAttrs[.posixPermissions] as? Int == 0o700)
  }

  @Test func recoverAllTwiceDoesNotDuplicate() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let spool = LiveSpool(directory: dir.appendingPathComponent("live"))
    let recovered = RecoveredTakes(directory: dir.appendingPathComponent("recovered"))
    let writer = try spool.open(takeId: "once99")
    writer.append([0.5])
    writer.close()
    #expect(spool.recoverAll(into: recovered) == 1)
    #expect(spool.recoverAll(into: recovered) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: recovered.directory.path).count == 1)
  }
}
