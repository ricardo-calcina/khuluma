import Foundation

/// Takes whose transcription timed out, kept privately so the user can
/// Retry (or Discard) from the menu. Each is a 16 kHz WAV of the take as
/// recorded (0600, in a 0700 folder) plus a JSON sidecar, and is removed
/// after `lifetime` (1 hour) or on retry/discard.
public struct TimedOutTakes: Sendable {
  /// What a retry needs to deliver and record the take like the original.
  public struct Info: Codable, Equatable, Sendable {
    public var takeId: String
    public var app: String?
    public var recordMs: Int
    public var startupMs: Int
    public var startedAtMs: Int
    public var savedAt: Date
    /// The daemon generation that timed out, for the log.
    public var generation: String?

    public init(takeId: String, app: String?, recordMs: Int, startupMs: Int, startedAtMs: Int,
                savedAt: Date = Date(), generation: String? = nil) {
      self.takeId = takeId
      self.app = app
      self.recordMs = recordMs
      self.startupMs = startupMs
      self.startedAtMs = startedAtMs
      self.savedAt = savedAt
      self.generation = generation
    }
  }

  public struct Entry: Equatable, Sendable {
    public let info: Info
    public let wav: URL
  }

  public static let lifetime: TimeInterval = 3600
  /// Saving, listing and removing take turns (the work queue saves while
  /// the menu lists), so a listing never sees a half-saved take.
  private static let lock = NSLock()

  public let directory: URL

  public static var standard: TimedOutTakes {
    TimedOutTakes(directory: AppRuntimePaths.temporary
      .appendingPathComponent("khuluma-timed-out", isDirectory: true))
  }

  public init(directory: URL) {
    self.directory = directory
  }

  @discardableResult
  public func save(samples: [Float], info: Info) throws -> Entry {
    try Self.lock.withLock { try saveLocked(samples: samples, info: info) }
  }

  private func saveLocked(samples: [Float], info: Info) throws -> Entry {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let entry = self.entry(for: info)
    let sidecar = entry.wav.deletingPathExtension().appendingPathExtension("json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    guard FileManager.default.createFile(
            atPath: entry.wav.path, contents: WAVEncoder.encode(samples: samples),
            attributes: [.posixPermissions: 0o600]),
          FileManager.default.createFile(
            atPath: sidecar.path, contents: try encoder.encode(info), attributes: [.posixPermissions: 0o600]) else {
      removeLocked(entry)
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: entry.wav.path])
    }
    return entry
  }

  /// Takes still within their lifetime, oldest first. Expired or broken
  /// ones are deleted.
  public func all(now: Date = Date()) -> [Entry] {
    Self.lock.withLock { allLocked(now: now) }
  }

  private func allLocked(now: Date) -> [Entry] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    var entries: [Entry] = []
    for name in names where name.hasSuffix(".json") {
      let sidecar = directory.appendingPathComponent(name)
      let wav = sidecar.deletingPathExtension().appendingPathExtension("wav")
      guard let data = try? Data(contentsOf: sidecar), let info = try? decoder.decode(Info.self, from: data),
            FileManager.default.fileExists(atPath: wav.path) else {
        try? FileManager.default.removeItem(at: sidecar)
        try? FileManager.default.removeItem(at: wav)
        continue
      }
      let entry = Entry(info: info, wav: wav)
      if now.timeIntervalSince(info.savedAt) >= Self.lifetime {
        removeLocked(entry)
      } else {
        entries.append(entry)
      }
    }
    // Orphaned audio (no sidecar) can't be retried.
    for name in names where name.hasSuffix(".wav") {
      let wav = directory.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("json").path) {
        try? FileManager.default.removeItem(at: wav)
      }
    }
    return entries.sorted { $0.info.savedAt < $1.info.savedAt }
  }

  public func remove(_ entry: Entry) {
    Self.lock.withLock { removeLocked(entry) }
  }

  private func removeLocked(_ entry: Entry) {
    try? FileManager.default.removeItem(at: entry.wav)
    try? FileManager.default.removeItem(at: entry.wav.deletingPathExtension().appendingPathExtension("json"))
  }

  private func entry(for info: Info) -> Entry {
    let safeId = String(info.takeId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
    return Entry(info: info, wav: directory.appendingPathComponent("\(safeId).wav"))
  }
}
