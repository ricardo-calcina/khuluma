import Foundation

/// Durable queue of takes waiting for `inline record`. Each record is written
/// here before persistence runs and removed once the CLI has recorded it, so
/// a quit that cannot wait, a crash or a failing CLI never loses a delivered
/// take: leftovers are replayed at the next launch (`inline record` skips take
/// IDs it has already recorded).
public struct PendingRecords: Sendable {
  public let directory: URL
  /// Leftovers older than this are dropped instead of replayed.
  public var maxAge: TimeInterval = 7 * 24 * 3600

  public static var standard: PendingRecords {
    PendingRecords(directory: FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Lowkey/pending", isDirectory: true))
  }

  public init(directory: URL) {
    self.directory = directory
  }

  /// Writes the record (0600, atomically) and returns its file.
  @discardableResult
  public func save(_ record: TakeRecord, at date: Date = Date()) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let name = String(format: "%013lld", Int64(date.timeIntervalSince1970 * 1000)) + "-\(record.takeId).json"
    let url = directory.appendingPathComponent(name)
    let temp = directory.appendingPathComponent(".\(name).tmp")
    let data = try JSONEncoder().encode(record)
    guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
    }
    if rename(temp.path, url.path) != 0 {
      try? FileManager.default.removeItem(at: temp)
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    return url
  }

  public func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// Leftover records, oldest first. Unreadable files and records older
  /// than `maxAge` are removed and reported in `dropped`.
  public func leftovers(now: Date = Date()) -> (records: [(url: URL, record: TakeRecord)], dropped: [String]) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
    var records: [(URL, TakeRecord)] = []
    var dropped: [String] = []
    for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
      let url = directory.appendingPathComponent(name)
      let millis = Double(name.prefix(while: \.isNumber)) ?? 0
      let tooOld = now.timeIntervalSince1970 - millis / 1000 > maxAge
      guard !tooOld, let data = FileManager.default.contents(atPath: url.path),
            let record = try? JSONDecoder().decode(TakeRecord.self, from: data) else {
        dropped.append(name)
        remove(url)
        continue
      }
      records.append((url, record))
    }
    return (records, dropped)
  }
}
