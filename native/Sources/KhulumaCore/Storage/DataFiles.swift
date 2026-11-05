import Darwin
import Foundation

/// File primitives for the app's own data (history, usage): the one data
/// lock and durable writes (temp file, fsync, rename or link, directory fsync).
public enum DataFiles {
  public struct Failure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }

  static func posix(_ what: String, _ path: String, _ code: Int32 = errno) -> Failure {
    Failure("\(what) \(path): \(String(cString: strerror(code)))")
  }

  /// Runs `body` holding an exclusive `flock` on `lockURL` (created if
  /// missing, never unlinked), retrying without blocking for up to `timeout`.
  /// Serializes writers across processes (a second copy of the app).
  public static func withLock<T>(_ lockURL: URL, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
    try ensureDirectory(lockURL.deletingLastPathComponent())
    let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw posix("cannot open lock", lockURL.path) }
    defer { close(fd) }
    // Monotonic: a wall-clock change must not stretch or skip the wait.
    let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(max(timeout, 0) * 1_000_000_000)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR else { throw posix("cannot lock", lockURL.path) }
      guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline else { throw Failure("data is locked by another process: \(lockURL.path)") }
      usleep(20_000)
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  public static func ensureDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
  }

  /// Writes `data` to a new 0600 temp file in `directory` and fsyncs it.
  static func writeTemp(_ data: Data, in directory: URL, prefix: String) throws -> String {
    var template = Array(directory.appendingPathComponent(prefix + "XXXXXX").path.utf8CString)
    let fd = mkstemp(&template)
    let path = String(cString: template)
    guard fd >= 0 else { throw posix("cannot create temp file in", directory.path) }
    var ok = data.withUnsafeBytes { raw -> Bool in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 { if errno == EINTR { continue }; return false }
        offset += n
      }
      return true
    }
    if ok { ok = fsync(fd) == 0 }
    let code = errno
    close(fd)
    guard ok else {
      unlink(path)
      throw posix("cannot write", path, code)
    }
    return path
  }

  /// Makes a rename or link in `url` durable. A failure is an error: the
  /// write is not done until the directory entry is on disk.
  public typealias SyncDirectory = @Sendable (URL) throws -> Void

  public static let syncDirectory: SyncDirectory = { url in
    var fd: Int32
    repeat { fd = open(url.path, O_RDONLY | O_CLOEXEC) } while fd < 0 && errno == EINTR
    guard fd >= 0 else { throw posix("cannot open directory", url.path) }
    defer { close(fd) }
    var result: Int32
    repeat { result = fsync(fd) } while result != 0 && errno == EINTR
    guard result == 0 else { throw posix("cannot sync directory", url.path) }
  }

  /// Best effort, for callers that cannot act on a failure.
  static func fsyncDirectory(_ url: URL) {
    try? syncDirectory(url)
  }

  /// Replaces `url` atomically: readers see the old or the new document.
  static func replace(_ url: URL, with data: Data, syncDirectory: SyncDirectory = DataFiles.syncDirectory) throws {
    let directory = url.deletingLastPathComponent()
    let temp = try writeTemp(data, in: directory, prefix: url.lastPathComponent + ".tmp-")
    guard rename(temp, url.path) == 0 else {
      let code = errno
      unlink(temp)
      throw posix("cannot replace", url.path, code)
    }
    try syncDirectory(directory)
  }
}
