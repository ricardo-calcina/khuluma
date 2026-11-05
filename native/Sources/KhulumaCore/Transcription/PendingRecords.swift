import Darwin
import Foundation

/// A spooled take plus which destinations already have it, so a replay redoes
/// only what is missing.
public struct PendingTake: Codable, Equatable, Sendable {
  public enum Destination: String, Sendable, CaseIterable {
    case history, bench, usage
  }

  public struct Done: Codable, Equatable, Sendable {
    public var history = false
    public var bench = false
    public var usage = false
    public init(history: Bool = false, bench: Bool = false, usage: Bool = false) {
      self.history = history
      self.bench = bench
      self.usage = usage
    }

    public subscript(_ destination: Destination) -> Bool {
      get {
        switch destination {
        case .history: history
        case .bench: bench
        case .usage: usage
        }
      }
      set {
        switch destination {
        case .history: history = newValue
        case .bench: bench = newValue
        case .usage: usage = newValue
        }
      }
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      history = try c.decodeIfPresent(Bool.self, forKey: .history) ?? false
      bench = try c.decodeIfPresent(Bool.self, forKey: .bench) ?? false
      usage = try c.decodeIfPresent(Bool.self, forKey: .usage) ?? false
    }

    enum Keys: String, CodingKey { case history, bench, usage }
  }

  public var record: TakeRecord
  public var done: Done

  public init(record: TakeRecord, done: Done = Done()) {
    self.record = record
    self.done = done
  }

  enum Keys: String, CodingKey { case record, done }

  /// Reads the wrapped shape, or a bare `TakeRecord` as written by build 415
  /// (nothing done).
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    if c.contains(.record) {
      record = try c.decode(TakeRecord.self, forKey: .record)
      done = try c.decodeIfPresent(Done.self, forKey: .done) ?? Done()
    } else {
      record = try TakeRecord(from: decoder)
      done = Done()
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(record, forKey: .record)
    try c.encode(done, forKey: .done)
  }
}

/// Durable queue of takes waiting to be recorded. Each record is written
/// here before persistence runs and removed once every destination has it, so
/// a quit that cannot wait, a crash or a failing writer never loses a
/// delivered take: leftovers are replayed at the next launch. Records never
/// expire; files that cannot be read are moved to `quarantine/`, never deleted.
public struct PendingRecords: Sendable {
  public let directory: URL
  private static let writeLock = NSLock()
  /// Hidden temp files older than this are quarantined.
  public var staleTempAge: TimeInterval = 3600

  public static var standard: PendingRecords {
    PendingRecords(directory: AppRuntimePaths.support.appendingPathComponent("pending", isDirectory: true))
  }

  public init(directory: URL) {
    self.directory = directory
  }

  public var quarantineDirectory: URL {
    directory.appendingPathComponent("quarantine", isDirectory: true)
  }

  /// Writes the record (0600, fsynced, atomically) and returns its file.
  @discardableResult
  public func save(_ record: TakeRecord, at date: Date = Date()) throws -> URL {
    try ensureDirectory(directory)
    let name = String(format: "%013lld", Int64(date.timeIntervalSince1970 * 1000)) + "-\(record.takeId).json"
    let url = directory.appendingPathComponent(name)
    Self.writeLock.lock()
    defer { Self.writeLock.unlock() }
    try write(PendingTake(record: record), to: url)
    return url
  }

  /// Sets one destination's flag and rewrites the file atomically.
  public func markDone(_ url: URL, _ destination: PendingTake.Destination) throws {
    // The whole read-modify-write is serialized in this process, so two
    // flags set at once cannot overwrite each other. (One app process owns
    // the spool, so there is no cross-process lock.)
    Self.writeLock.lock()
    defer { Self.writeLock.unlock() }
    let data = try Data(contentsOf: url)
    var take = try JSONDecoder().decode(PendingTake.self, from: data)
    guard !take.done[destination] else { return }
    take.done[destination] = true
    try write(take, to: url)
  }

  public func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// Leftover records, oldest first, with their flags. Unreadable files and
  /// stale temp files are moved to `quarantine/` and their names reported.
  public func leftovers(now: Date = Date()) -> (records: [(url: URL, take: PendingTake)], quarantined: [String]) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
    var records: [(URL, PendingTake)] = []
    var quarantined: [String] = []
    for name in names.sorted() {
      let url = directory.appendingPathComponent(name)
      if name.hasPrefix(".") {
        guard name.hasSuffix(".tmp"), let modified = Self.modified(url),
              now.timeIntervalSince(modified) > staleTempAge else { continue }
        if quarantine(url) { quarantined.append(name) }
      } else if name.hasSuffix(".json") {
        if let data = FileManager.default.contents(atPath: url.path),
           let take = try? JSONDecoder().decode(PendingTake.self, from: data) {
          records.append((url, take))
        } else if quarantine(url) {
          quarantined.append(name)
        }
      }
    }
    return (records, quarantined)
  }

  // MARK: - Files

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  private func ensureDirectory(_ dir: URL) throws {
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // An existing directory keeps its old mode, so enforce it.
    if chmod(dir.path, 0o700) != 0 { throw Self.posixError(dir.path) }
  }

  /// Renames the file into `quarantine/` without overwriting anything there;
  /// false if that failed (it is left in place, never deleted).
  private func quarantine(_ url: URL) -> Bool {
    do { try ensureDirectory(quarantineDirectory) } catch { return false }
    var target = quarantineDirectory.appendingPathComponent(url.lastPathComponent)
    for _ in 0..<8 {
      if renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) == 0 { return true }
      guard errno == EEXIST else { return false }
      target = quarantineDirectory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
    }
    return false
  }

  /// Unique exclusive temp file 0600 in the same directory, fsync, rename,
  /// fsync the directory. Succeeds only after the directory fsync.
  private func write(_ take: PendingTake, to url: URL) throws {
    let data = try JSONEncoder().encode(take)
    let dir = url.deletingLastPathComponent()
    let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
    var fd: Int32
    repeat { fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600) } while fd < 0 && errno == EINTR
    guard fd >= 0 else { throw Self.posixError(temp.path) }
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
    if code == 0, let e = Self.sync(fd) { code = e }
    close(fd)
    if code != 0 {
      unlink(temp.path)
      throw Self.posixError(temp.path, code: code)
    }
    if rename(temp.path, url.path) != 0 {
      let e = errno
      unlink(temp.path)
      throw Self.posixError(url.path, code: e)
    }
    var dirFd: Int32
    repeat { dirFd = open(dir.path, O_RDONLY) } while dirFd < 0 && errno == EINTR
    guard dirFd >= 0 else { throw Self.posixError(dir.path) }
    let syncError = Self.sync(dirFd)
    close(dirFd)
    if let syncError { throw Self.posixError(dir.path, code: syncError) }
  }

  /// fsync with EINTR retried; the errno on failure.
  private static func sync(_ fd: Int32) -> Int32? {
    while fsync(fd) != 0 {
      if errno != EINTR { return errno }
    }
    return nil
  }

  private static func posixError(_ path: String, code: Int32 = errno) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
  }
}
