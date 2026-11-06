import Foundation

/// Takes whose transcription timed out, kept privately so the user can
/// Retry (or Discard) from the menu. Each is a 16 kHz WAV of the take as
/// recorded (0600, in a 0700 folder) plus a JSON sidecar. After `lifetime`
/// (1 hour) it is handed to recovered/ (transcribed into history, never
/// pasted), not deleted; only Discard, a finished retry or audio with no
/// samples deletes it.
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
  /// Where expired, orphaned or broken-sidecar audio goes.
  public let recovered: RecoveredTakes

  /// In the app folder, not $TMPDIR: macOS purges unused temp files after
  /// about three days, which would lose a take before its handoff ran.
  public static var standard: TimedOutTakes {
    TimedOutTakes(directory: AppRuntimePaths.support.appendingPathComponent("timed-out", isDirectory: true),
                  recovered: .standard)
  }

  /// Where build 415 and earlier kept them ($TMPDIR, or the isolated
  /// temporary folder).
  public static var legacyDirectory: URL {
    legacyDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  public static func legacyDirectory(environment: [String: String], home: URL) -> URL {
    AppRuntimePaths.temporaryDirectory(environment: environment, home: home)
      .appendingPathComponent("khuluma-timed-out", isDirectory: true)
  }

  /// Moves takes left in `old` into this store: each file is durably copied
  /// (audio before its sidecar) and only then removed from `old`. A file
  /// whose name is already taken here by different bytes is left in `old`.
  /// Broken or orphaned files come across as they are; `all()` hands them
  /// to recovered/. Returns how many files moved.
  @discardableResult
  public func adoptLegacy(from old: URL) -> Int {
    Self.lock.withLock {
      guard old.standardizedFileURL != directory.standardizedFileURL,
            let names = try? FileManager.default.contentsOfDirectory(atPath: old.path) else { return 0 }
      let files = names.filter { !$0.hasPrefix(".") && ($0.hasSuffix(".wav") || $0.hasSuffix(".json")) }
        .sorted { ($0.hasSuffix(".wav") ? 0 : 1, $0) < ($1.hasSuffix(".wav") ? 0 : 1, $1) }
      guard !files.isEmpty else { return 0 }
      do {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { return 0 }
      var moved = 0
      for name in files {
        let source = old.appendingPathComponent(name)
        let target = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: source) else { continue }
        if let existing = try? Data(contentsOf: target) {
          guard existing == data else { continue }
        } else {
          do { try DurableFile.write(data, to: target) } catch { continue }
        }
        try? FileManager.default.removeItem(at: source)
        moved += 1
      }
      if (try? FileManager.default.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
        try? FileManager.default.removeItem(at: old)
      }
      return moved
    }
  }

  public init(directory: URL, recovered: RecoveredTakes) {
    self.directory = directory
    self.recovered = recovered
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
      guard FileManager.default.fileExists(atPath: wav.path) else {
        // A sidecar with no audio: nothing to keep.
        try? FileManager.default.removeItem(at: sidecar)
        continue
      }
      guard let data = try? Data(contentsOf: sidecar), let info = try? decoder.decode(Info.self, from: data) else {
        // Broken sidecar: the audio still goes to recovered/, under a new id.
        handOff(wav: wav, sidecar: sidecar, takeId: UUID().uuidString.lowercased(), now: now)
        continue
      }
      let entry = Entry(info: info, wav: wav)
      if now.timeIntervalSince(info.savedAt) >= Self.lifetime {
        // Same id: recovery skips it if a retry already saved it.
        if !handOff(wav: wav, sidecar: sidecar, takeId: info.takeId, now: now) { entries.append(entry) }
      } else {
        entries.append(entry)
      }
    }
    // Audio without a sidecar can't be retried, but is still a take.
    for name in names where name.hasSuffix(".wav") {
      let wav = directory.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("json").path) {
        handOff(wav: wav, sidecar: nil, takeId: UUID().uuidString.lowercased(), now: now)
      }
    }
    return entries.sorted { $0.info.savedAt < $1.info.savedAt }
  }

  /// Moves a take's audio to recovered/ (durably first), then removes it
  /// here. Audio that can't be read or has no samples is deleted; if the
  /// handoff fails, everything stays for the next listing. Returns whether
  /// the files here are gone.
  @discardableResult
  private func handOff(wav: URL, sidecar: URL?, takeId: String, now: Date) -> Bool {
    let removeHere = {
      try? FileManager.default.removeItem(at: wav)
      if let sidecar { try? FileManager.default.removeItem(at: sidecar) }
    }
    guard let data = try? Data(contentsOf: wav) else {
      if FileManager.default.isReadableFile(atPath: wav.path) { return false }
      removeHere()
      return true
    }
    guard data.count > 44 else {
      removeHere()
      return true
    }
    do {
      try recovered.adopt(wav: data, takeId: takeId, at: now)
    } catch {
      return false
    }
    removeHere()
    return true
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
