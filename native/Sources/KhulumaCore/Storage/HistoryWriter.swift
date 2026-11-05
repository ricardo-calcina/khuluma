import Darwin
import Foundation

/// Per-take history files (`history/<local YYYY-MM-DDTHH-MM-SS>[_N].json`),
/// in the CLI's `save_history` shape plus `take_id`, so imported history reads
/// the same. Entries older than the retention go to the Trash. The caller
/// holds the data lock.
public struct HistoryWriter: Sendable {
  public let directory: URL
  public var retentionDays: Int
  public var now: @Sendable () -> Date
  public var timeZone: TimeZone
  /// Moves an expired entry somewhere recoverable (the Trash by default).
  public var trash: @Sendable (URL) throws -> Void
  public var syncDirectory: DataFiles.SyncDirectory = DataFiles.syncDirectory

  public init(directory: URL, retentionDays: Int = 7, now: @escaping @Sendable () -> Date = { Date() },
              timeZone: TimeZone = .current,
              trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
    self.directory = directory
    self.retentionDays = retentionDays
    self.now = now
    self.timeZone = timeZone
    self.trash = trash
  }

  public struct Entry: Sendable {
    public var app: String
    public var raw: String
    public var processed: String
    public var takeId: String?
    /// record_ms, transcribe_ms, clean_ms, paste_ms, total_ms, in that order.
    public var metrics: [(String, Int)]
    /// Ints or strings, in the CLI's order.
    public var audio: [(String, AudioValue)]

    public init(app: String, raw: String, processed: String, takeId: String?,
                metrics: [(String, Int)], audio: [(String, AudioValue)] = []) {
      self.app = app
      self.raw = raw
      self.processed = processed
      self.takeId = takeId
      self.metrics = metrics
      self.audio = audio
    }
  }

  public enum AudioValue: Sendable, Equatable {
    case int(Int)
    case string(String)
  }

  public enum Outcome: Equatable, Sendable {
    case saved(URL)
    case alreadySaved(URL)
  }

  /// Prunes expired entries (sparing `protectedTakeIds`, the takes still in
  /// the spool), then saves the entry once per take id.
  public func save(_ entry: Entry, protectedTakeIds: Set<String> = [], log: (String) -> Void = { _ in }) throws -> Outcome {
    try DataFiles.ensureDirectory(directory)
    do { try prune(protecting: protectedTakeIds) } catch { log("history: retention cleanup failed: \(error.localizedDescription)") }
    if let takeId = entry.takeId, !takeId.isEmpty, let existing = entryURL(takeId: takeId) {
      return .alreadySaved(existing)
    }
    let data = Data(document(entry).utf8)
    let temp = try DataFiles.writeTemp(data, in: directory, prefix: ".history.tmp-")
    defer { unlink(temp) }
    let stem = Self.localStamp(now(), timeZone)
    for n in 1...50 {
      let target = directory.appendingPathComponent(n == 1 ? "\(stem).json" : "\(stem)_\(n).json")
      // link() fails if the name exists: an exclusive create of a complete file.
      if link(temp, target.path) == 0 {
        // Not durable until the directory is synced; a replay then finds the
        // entry by take id and reports it already saved.
        try syncDirectory(directory)
        return .saved(target)
      }
      guard errno == EEXIST else { throw DataFiles.posix("cannot publish", target.path) }
    }
    throw DataFiles.Failure("history: no free name for \(stem)")
  }

  /// The entry already saved for this take, if any.
  public func entryURL(takeId: String) -> URL? {
    let needle = Data("\"take_id\"".utf8)
    for url in entries() {
      guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["take_id"] as? String == takeId else { continue }
      return url
    }
    return nil
  }

  /// `find history -name '*.json' -mtime +N`: whole days of age above N.
  /// An entry whose take is still spooled is kept: if it went, the take's
  /// replay would save it again.
  public func prune(protecting protectedTakeIds: Set<String> = []) throws {
    let cutoff = now().timeIntervalSince1970
    guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
    var expired: [URL] = []
    for case let url as URL in walker where url.pathExtension == "json" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
      if Int(floor((cutoff - modified.timeIntervalSince1970) / 86400)) > retentionDays { expired.append(url) }
    }
    for url in expired {
      if !protectedTakeIds.isEmpty, let data = try? Data(contentsOf: url),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let takeId = object["take_id"] as? String, protectedTakeIds.contains(takeId) { continue }
      try trash(url)
    }
  }

  func entries() -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
      .map { directory.appendingPathComponent($0) }
  }

  func document(_ entry: Entry) -> String {
    var lines = [
      "  \"timestamp\": \(Self.json(UsageLedger.isoStamp(now())))",
      "  \"app\": \(Self.json(entry.app))",
      "  \"raw\": \(Self.json(entry.raw))",
      "  \"processed\": \(Self.json(entry.processed))",
    ]
    if let takeId = entry.takeId, !takeId.isEmpty { lines.append("  \"take_id\": \(Self.json(takeId))") }
    if !entry.metrics.isEmpty {
      let body = entry.metrics.map { "    \"\($0.0)\": \($0.1)" }.joined(separator: ",\n")
      lines.append("  \"metrics\": {\n\(body)\n  }")
    }
    if !entry.audio.isEmpty {
      let body = entry.audio.map { key, value -> String in
        switch value {
        case .int(let n): return "    \"\(key)\": \(n)"
        case .string(let s): return "    \"\(key)\": \(Self.json(s))"
        }
      }.joined(separator: ",\n")
      lines.append("  \"audio\": {\n\(body)\n  }")
    }
    return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
  }

  static func json(_ string: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  /// Local `YYYY-MM-DDTHH-MM-SS`.
  static func localStamp(_ date: Date, _ timeZone: TimeZone) -> String {
    let c = Calendar.gregorian(timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d-%02d-%02dT%02d-%02d-%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
  }
}

/// The `[debug] keep_logs` archive: the padded WAV a take was transcribed
/// from plus a `.meta` file, in `history/inline-debug/`. WAVs expire after
/// the audio retention (48 h by default), deleted outright, not trashed.
public struct DebugArchive: Sendable {
  public let directory: URL
  public var audioRetentionDays: Int
  public var now: @Sendable () -> Date
  public var timeZone: TimeZone

  public init(directory: URL, audioRetentionDays: Int = 2, now: @escaping @Sendable () -> Date = { Date() },
              timeZone: TimeZone = .current) {
    self.directory = directory
    self.audioRetentionDays = audioRetentionDays
    self.now = now
    self.timeZone = timeZone
  }

  public static func safeName(_ takeId: String) -> String {
    String(String.UnicodeScalarView(takeId.unicodeScalars.map {
      ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_"
    }))
  }

  /// The history `audio` fields for an archived take.
  public struct Saved: Sendable {
    public let prefix: String
    public let wavMs: Int?
    public let wavBytes: Int?
  }

  public var retentionNote: String {
    "WAV retained for \(audioRetentionDays) day(s); JSON history and .meta/.log artifacts remain for stats/roundups."
  }

  /// Archives `wav` once per take (a replay reuses the earlier archive).
  /// nil if nothing could be archived.
  public func archive(wav: URL, record: TakeRecord, captureGapMs: Int?) -> Saved? {
    guard (try? DataFiles.ensureDirectory(directory)) != nil else { return nil }
    let safe = Self.safeName(record.takeId.isEmpty ? "khuluma" : record.takeId)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    if !record.takeId.isEmpty, let meta = names.sorted().first(where: { $0.hasSuffix("-\(safe).meta") }) {
      let prefix = directory.appendingPathComponent(String(meta.dropLast(5))).path
      return Saved(prefix: prefix, wavMs: Self.wavDurationMs(URL(fileURLWithPath: prefix + ".wav")),
                   wavBytes: Self.fileSize(prefix + ".wav"))
    }
    let prefix = directory.appendingPathComponent("\(HistoryWriter.localStamp(now(), timeZone))-\(safe)").path
    let wavMs = Self.wavDurationMs(wav)
    let wavBytes = Self.fileSize(wav.path)
    let copied = (try? Self.copy(wav, to: URL(fileURLWithPath: prefix + ".wav"))) != nil
    let fields: [(String, String)] = [
      ("session_id", record.takeId),
      ("status", record.status),
      ("record_ms", String(max(record.recordMs, 0))),
      ("capture_wav_ms", record.captureWavMs.map(String.init) ?? ""),
      ("capture_wav_bytes", record.captureWavBytes.map(String.init) ?? ""),
      ("capture_gap_to_record_ms", captureGapMs.map(String.init) ?? ""),
      ("archive_wav_ms", wavMs.map(String.init) ?? ""),
      ("archive_wav_bytes", wavBytes.map(String.init) ?? ""),
      ("wav_retention_days", String(audioRetentionDays)),
      ("retention_note", retentionNote),
      ("transcribe_ms", String(max(record.transcribeMs, 0))),
      ("clean_ms", String(max(record.cleanMs, 0))),
      ("paste_ms", String(max(record.pasteMs, 0))),
      ("total_ms", String(max(record.totalMs, 0))),
      ("archived_at", UsageLedger.isoStamp(now())),
    ]
    let meta = fields.map { "\($0.0)=\(Self.shellQuoted($0.1))\n" }.joined()
    try? Data(meta.utf8).write(to: URL(fileURLWithPath: prefix + ".meta"), options: .atomic)
    return copied ? Saved(prefix: prefix, wavMs: wavMs, wavBytes: wavBytes) : nil
  }

  /// Deletes archived WAVs at least `audioRetentionDays` × 24 h old.
  public func expire() throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0 else { return }
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
      throw DataFiles.Failure("refusing unowned or symlink audio archive: \(directory.path)")
    }
    let cutoff = now().timeIntervalSince1970 - Double(audioRetentionDays) * 86400
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".wav") {
      let path = directory.appendingPathComponent(name).path
      var file = stat()
      guard lstat(path, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG, file.st_uid == getuid() else { continue }
      if Double(file.st_mtimespec.tv_sec) <= cutoff { unlink(path) }
    }
  }

  /// Removes the app's own working WAV once it is no longer needed: an owned,
  /// singly linked regular file named like a Khuluma take, directly inside
  /// one of `roots`.
  public static func deleteWorkingAudio(_ path: String, roots: [URL]) -> Bool {
    let url = URL(fileURLWithPath: path)
    var info = stat()
    guard lstat(path, &info) == 0 else { return true }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
    let allowed = Set(roots.map { $0.resolvingSymlinksInPath().path })
    let name = url.lastPathComponent
    let named = (name.hasPrefix("khuluma-") && name.hasSuffix(".wav")
                 && name.dropFirst(8).dropLast(4).allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "." || $0 == "-" }
                 && name.count > 12)
      || (name.hasPrefix("khuluma-app-take.") && name.count > 17)
    guard allowed.contains(parent), (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
          info.st_nlink == 1, named else { return false }
    return unlink(path) == 0
  }

  static func copy(_ source: URL, to target: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.copyItem(at: source, to: target)
  }

  static func fileSize(_ path: String) -> Int? {
    var info = stat()
    return stat(path, &info) == 0 ? Int(info.st_size) : nil
  }

  /// Duration of a PCM WAV from its header (the CLI asked ffprobe).
  static func wavDurationMs(_ url: URL) -> Int? {
    guard let data = try? Data(contentsOf: url), data.count >= 12,
          data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return nil }
    func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
    var offset = 12
    var byteRate: Int?
    while offset + 8 <= data.count {
      let id = data[offset..<offset + 4], size = u32(offset + 4)
      if id == Data("fmt ".utf8), offset + 16 <= data.count { byteRate = u32(offset + 16) }
      if id == Data("data".utf8) {
        guard let rate = byteRate, rate > 0 else { return nil }
        let bytes = min(size, data.count - offset - 8)
        return Int((Double(bytes) / Double(rate) * 1000).rounded())
      }
      offset += 8 + size + (size & 1)
    }
    return nil
  }

  /// Like bash `printf %q` for the characters the meta values hold.
  static func shellQuoted(_ value: String) -> String {
    if value.isEmpty { return "''" }
    var out = ""
    for scalar in value.unicodeScalars {
      let plain = ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        || ",._+:@%/-=".unicodeScalars.contains(scalar) || scalar.value > 0x7F
      if !plain { out += "\\" }
      out.unicodeScalars.append(scalar)
    }
    return out
  }
}
