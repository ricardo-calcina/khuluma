import Foundation

/// The recording on disk while it is being made ("transcribe while
/// recording"): raw little-endian PCM16 appended as capture arrives, so an
/// interrupted take can be recovered at the next launch. `<takeId>.pcm` in
/// the support folder's `live/`, 0700/0600 like the rest.
public struct LiveSpool: Sendable {
  public let directory: URL

  public static var standard: LiveSpool {
    LiveSpool(directory: AppRuntimePaths.support.appendingPathComponent("live", isDirectory: true))
  }

  public init(directory: URL) {
    self.directory = directory
  }

  public func open(takeId: String) throws -> Writer {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("\(takeId).pcm")
    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return Writer(url: url)
  }

  /// Launch: turn every leftover spool file into a recovered take and delete
  /// it. Returns how many were recovered; a failure leaves the file for the
  /// next launch, an empty file is just deleted.
  @discardableResult
  public func recoverAll(into recovered: RecoveredTakes) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var count = 0
    for name in names where name.hasSuffix(".pcm") {
      let url = directory.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url) else { continue }
      if data.isEmpty {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      // The spool is raw LE PCM16; adopt wraps it in a WAV as recovered/.
      let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      guard (try? recovered.adopt(wav: WAVEncoder.encode(pcm: pcm), takeId: String(name.dropLast(4)))) != nil
      else { continue }
      try? FileManager.default.removeItem(at: url)
      count += 1
    }
    return count
  }

  /// One open spool file. `append` never throws: a write failure closes the
  /// writer (the audio then just lives in memory).
  public final class Writer: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var broken = false

    init(url: URL) {
      self.url = url
      handle = try? FileHandle(forWritingTo: url)
    }

    public func append(_ samples: [Float]) {
      guard !samples.isEmpty else { return }
      let pcm = WAVEncoder.pcm16(samples)
      let data = pcm.withUnsafeBufferPointer { buffer in
        Data(bytes: buffer.baseAddress!, count: buffer.count * 2)
      }
      lock.withLock {
        guard let handle, !broken else { return }
        do { try handle.write(contentsOf: data) }
        catch {
          broken = true
          try? handle.close()
        }
      }
    }

    public func close() {
      lock.withLock {
        try? handle?.close()
        handle = nil
      }
    }

    public func remove() {
      lock.withLock {
        try? handle?.close()
        handle = nil
      }
      try? FileManager.default.removeItem(at: url)
    }
  }
}
