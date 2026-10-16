import Foundation

/// Audio of takes that were still recording when Lowkey quit. Written before
/// anything else happens at quit, so a dictation survives even if there's no
/// time to transcribe it; the next launch transcribes leftovers into history.
public struct RecoveredTakes: Sendable {
  public let directory: URL

  public static var standard: RecoveredTakes {
    RecoveredTakes(directory: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Lowkey/recovered", isDirectory: true))
  }

  public init(directory: URL) {
    self.directory = directory
  }

  /// Writes the take as a 16 kHz 16-bit WAV (0600) and returns its file.
  public func save(samples: [Float], takeId: String, at date: Date = Date()) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let name = String(format: "%013lld", Int64(date.timeIntervalSince1970 * 1000)) + "-\(takeId).wav"
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.createFile(
      atPath: url.path, contents: WAVEncoder.encode(samples: samples), attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return url
  }

  /// Saved takes, oldest first.
  public func all() -> [URL] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
    return names.filter { $0.hasSuffix(".wav") && !$0.hasPrefix(".") }.sorted()
      .map { directory.appendingPathComponent($0) }
  }

  /// Samples of a WAV written by `save` (44-byte header, 16-bit mono PCM).
  public static func samples(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 44 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
    let pcm: [Int16] = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    return pcm.map { Float($0) / 32767 }
  }

  /// The take id encoded in a saved file's name.
  public static func takeId(of url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent
    guard let dash = stem.firstIndex(of: "-") else { return stem }
    return String(stem[stem.index(after: dash)...])
  }

  public func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
