import Darwin
import Foundation

/// Audio of takes that were still recording when Khuluma quit. Written before
/// anything else happens at quit, so a dictation survives even if there's no
/// time to transcribe it; the next launch transcribes leftovers into history.
public struct RecoveredTakes: Sendable {
  public let directory: URL

  public static var standard: RecoveredTakes {
    RecoveredTakes(directory: AppRuntimePaths.support.appendingPathComponent("recovered", isDirectory: true))
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

  /// Hands over a WAV that already exists elsewhere (a timed-out take that
  /// expired): written to a temp file in recovered/, fsynced, renamed into
  /// place and the folder fsynced, so the caller may delete its copy once
  /// this returns. Idempotent: if recovered/ already holds this take id
  /// with the same bytes (a crash after the copy, before the source was
  /// removed), that file is synced and returned instead of a second copy.
  @discardableResult
  public func adopt(wav data: Data, takeId: String, at date: Date = Date()) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var safeId = String(takeId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
    if safeId.isEmpty { safeId = "take" }
    for existing in all() where Self.takeId(of: existing) == safeId {
      if (try? Data(contentsOf: existing)) == data {
        try DurableFile.syncExisting(existing)
        return existing
      }
    }
    let name = String(format: "%013lld", Int64(date.timeIntervalSince1970 * 1000)) + "-\(safeId).wav"
    let url = directory.appendingPathComponent(name)
    try DurableFile.write(data, to: url)
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

/// Crash-safe file writes: an exclusive 0600 temp file in the same folder,
/// fsync, rename into place, fsync the folder. Done only after the folder
/// fsync, so a caller may then delete its own copy.
enum DurableFile {
  /// fsyncs an existing file and its folder (before a caller deletes its
  /// own copy because this one already matches).
  static func syncExisting(_ url: URL) throws {
    func failure(_ path: String, _ code: Int32) -> Error {
      NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
    for (path, flags) in [(url.path, O_RDONLY), (url.deletingLastPathComponent().path, O_RDONLY)] {
      var fd: Int32
      repeat { fd = open(path, flags) } while fd < 0 && errno == EINTR
      guard fd >= 0 else { throw failure(path, errno) }
      var code: Int32 = 0
      while fsync(fd) != 0 { if errno != EINTR { code = errno; break } }
      close(fd)
      if code != 0 { throw failure(path, code) }
    }
  }

  /// Makes `url` hold `data` durably: synced if it already does, written if
  /// missing; throws if it holds something else.
  static func ensure(_ data: Data, at url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      guard (try? Data(contentsOf: url)) == data else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSFilePathErrorKey: url.path])
      }
      try syncExisting(url)
    } else {
      try write(data, to: url)
    }
  }

  static func write(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
    func failure(_ path: String, _ code: Int32) -> Error {
      NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
    func sync(_ fd: Int32) -> Int32? {
      while fsync(fd) != 0 { if errno != EINTR { return errno } }
      return nil
    }
    var fd: Int32
    repeat { fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600) } while fd < 0 && errno == EINTR
    guard fd >= 0 else { throw failure(temp.path, errno) }
    var code: Int32 = 0
    if fchmod(fd, 0o600) != 0 { code = errno }
    if code == 0 {
      data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
          if n < 0 {
            if errno == EINTR { continue }
            code = errno
            return
          }
          offset += n
        }
      }
    }
    if code == 0, let e = sync(fd) { code = e }
    close(fd)
    if code != 0 {
      unlink(temp.path)
      throw failure(temp.path, code)
    }
    if rename(temp.path, url.path) != 0 {
      let e = errno
      unlink(temp.path)
      throw failure(url.path, e)
    }
    var dirFd: Int32
    repeat { dirFd = open(directory.path, O_RDONLY) } while dirFd < 0 && errno == EINTR
    guard dirFd >= 0 else { throw failure(directory.path, errno) }
    let syncError = sync(dirFd)
    close(dirFd)
    if let syncError { throw failure(directory.path, syncError) }
  }
}
