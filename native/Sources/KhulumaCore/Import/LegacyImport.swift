import Darwin
import Foundation

/// One-time copy of the retired CLI's data (`~/.config/khuluma`) into the app
/// folder. Copies, never moves: the source is only read. Never merges over
/// newer app data. Writes `import.json` last, so a crash leaves no receipt and
/// the next run cleans up and starts again.
///
/// Settings: `config.toml` (or `.config.toml.last-good` when it doesn't
/// parse) is converted to `settings.json` (`LegacySettings`); keys not carried
/// over are listed in the receipt's `skipped`. The receipt's `settings` is
/// "imported"; "defaults_no_autosend" when the CLI had a config but neither
/// file converts (settings.json gets defaults with autosend off and an
/// `import_warning`); "defaults" when there was no config.
public enum LegacyImport {
  public static let receiptName = "import.json"
  public static let legacyTakeIDsName = "legacy-take-ids.json"
  static let stagingName = ".import-staging"
  static let journalName = ".import-journal.json"
  static let lockName = ".data.lock"
  static let ledgerNames = ["recorded-takes", "recorded-takes-history", "recorded-takes-bench"]

  // MARK: Source

  public struct Source: Equatable, Sendable {
    public let root: URL
    public let usage: URL
  }

  /// Same resolution as `bin/khuluma`: KHULUMA_CONFIG_DIR, else
  /// $XDG_CONFIG_HOME/khuluma, else ~/.config/khuluma; usage at
  /// KHULUMA_USAGE_SUMMARY_FILE, else <root>/usage.json.
  public static func source(environment: [String: String], home: URL) -> Source {
    func value(_ key: String) -> String? {
      guard let v = environment[key], !v.isEmpty else { return nil }
      return v
    }
    let xdg = value("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? home.appendingPathComponent(".config", isDirectory: true)
    let root = value("KHULUMA_CONFIG_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? xdg.appendingPathComponent("khuluma", isDirectory: true)
    let usage = value("KHULUMA_USAGE_SUMMARY_FILE").map { URL(fileURLWithPath: $0) }
      ?? root.appendingPathComponent("usage.json")
    return Source(root: root, usage: usage)
  }

  // MARK: Result

  public struct UsageTotals: Equatable, Sendable, Codable {
    public var count: Int
    public var processed_words: Int
    public var recording_duration_ms: Int
  }

  public struct Skipped: Equatable, Sendable, Codable {
    public var path: String
    public var reason: String
  }

  public struct Counts: Equatable, Sendable, Codable {
    public var history = 0
    public var history_invalid = 0
    public var debug_files = 0
    public var vocabulary_backups = 0
  }

  public struct UsageReceipt: Equatable, Sendable, Codable {
    public var source: UsageTotals?
    public var imported: UsageTotals?
  }

  public struct Receipt: Equatable, Sendable, Codable {
    public var version = 1
    public var imported_at: String
    public var source_root: String
    public var counts: Counts
    public var usage: UsageReceipt
    public var vocabulary: Bool
    /// The CLI's plain-text `vocab` list, offered by the vocabulary editor when
    /// there's no vocabulary.json (as `vocab-sheet show` did).
    public var legacy_vocab: Bool
    public var legacy_take_ids: Int
    public var skipped: [Skipped]
    public var settings: String
  }

  public enum Outcome: Equatable, Sendable {
    case imported(Receipt)
    case alreadyImported
    case noSource(String)
    case refused(String)
    case failed(String)
  }

  public struct Result: Equatable, Sendable {
    public let outcome: Outcome
    public let duration: TimeInterval

    /// One line for app.log.
    public var logLine: String {
      let ms = Int((duration * 1000).rounded())
      switch outcome {
      case .imported(let r):
        let c = r.counts
        let u = r.usage.imported.map { "usage \($0.count) takes/\($0.processed_words) words" } ?? "usage not imported"
        return "legacy import: done from \(r.source_root): history \(c.history) (+\(c.history_invalid) invalid), "
          + "debug \(c.debug_files), vocabulary \(r.vocabulary ? "yes" : "no") (+\(c.vocabulary_backups) backups), vocab \(r.legacy_vocab ? "yes" : "no"), "
          + "\(u), take ids \(r.legacy_take_ids), skipped \(r.skipped.count), \(ms) ms"
      case .alreadyImported: return "legacy import: already done (\(ms) ms)"
      case .noSource(let p): return "legacy import: no CLI data at \(p) (\(ms) ms)"
      case .refused(let why): return "legacy import: refused: \(why) (\(ms) ms)"
      case .failed(let why): return "legacy import: failed: \(why) (\(ms) ms)"
      }
    }
  }

  /// Test seam: called after staging is verified, before anything moves into
  /// place (`.staged`), after each promoted item (`.promoted(relative path)`)
  /// and after all moves, before the receipt (`.moved`).
  public enum Checkpoint: Sendable, Equatable { case staged, promoted(String), moved }


  // MARK: Entry point

  /// Runs the import once. Safe to call on every launch: a no-op when the
  /// receipt exists or there's no CLI data.
  public static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         destination: URL = AppRuntimePaths.support,
                         lockTimeout: TimeInterval = 10,
                         now: Date = Date(),
                         checkpoint: (Checkpoint) throws -> Void = { _ in }) -> Result {
    let started = Date()
    let src = source(environment: environment, home: home)
    let outcome: Outcome
    do {
      try DataFiles.ensureDirectory(destination)
      outcome = try DataFiles.withLock(destination.appendingPathComponent(lockName), timeout: lockTimeout) {
        try locked(src, destination, now, checkpoint)
      }
    } catch {
      outcome = .failed(error.localizedDescription)
    }
    return Result(outcome: outcome, duration: Date().timeIntervalSince(started))
  }

  static func failure(_ message: String) -> DataFiles.Failure { DataFiles.Failure(message) }

  /// What one import run stages: per-file identities (relative path under the
  /// staging dir) gathered while copying, so nothing is walked twice.
  final class Stage {
    let root: URL
    var identities: [String: Identity] = [:]
    var skipped: [Skipped] = []
    init(root: URL) { self.root = root }
  }

  static func locked(_ src: Source, _ dest: URL, _ now: Date,
                     _ checkpoint: (Checkpoint) throws -> Void) throws -> Outcome {
    if lstatMode(dest.appendingPathComponent(receiptName)) != nil { return .alreadyImported }
    guard lstatMode(src.root) != nil, isDirectory(src.root) || isDirectoryFollowing(src.root) else {
      return .noSource(src.root.path)
    }
    if let overlap = overlapIssue(src, dest) { return .refused(overlap) }
    if let link = symlinkIssue(dest) { return .refused(link) }

    // Leftovers of an interrupted run: undo its promoted copies, drop staging.
    let kept = try rollBackJournal(dest)
    let staging = dest.appendingPathComponent(stagingName, isDirectory: true)
    try removeStaging(staging)

    if let conflict = existingAppData(dest) {
      let note = kept.isEmpty ? "" : "; kept after an interrupted import: " + kept.map { "\($0.path) (\($0.reason))" }.joined(separator: ", ")
      return .refused(conflict + note)
    }

    let stage = Stage(root: staging)
    try makePrivateDirectory(staging)
    var counts = Counts()
    var usage = UsageReceipt()

    // History: top-level *.json files, then the debug archive.
    let history = src.root.appendingPathComponent("history", isDirectory: true)
    if isDirectoryFollowing(history) {
      let stagedHistory = staging.appendingPathComponent("history", isDirectory: true)
      try makePrivateDirectory(stagedHistory)
      for name in try FileManager.default.contentsOfDirectory(atPath: history.path).sorted() where name.hasSuffix(".json") {
        let file = history.appendingPathComponent(name)
        guard let data = try copyFile(file, rel: "history/" + name, stage: stage, keepData: true) else { continue }
        if parsesAsObject(data) { counts.history += 1 } else {
          counts.history_invalid += 1
          stage.skipped.append(Skipped(path: file.path, reason: "invalid history JSON (copied as-is)"))
        }
      }
      let debug = history.appendingPathComponent("inline-debug", isDirectory: true)
      if isDirectory(debug) {
        counts.debug_files = try copyTree(debug, rel: "history/inline-debug", stage: stage)
      }
      try syncDirectory(stagedHistory)
      try copyTimes(history, stagedHistory)
    }

    // Usage: a regular file, schema 1, readable totals.
    switch try readRegular(src.usage) {
    case .missing: break
    case .notRegular:
      stage.skipped.append(Skipped(path: src.usage.path, reason: "usage.json is not a regular file; not imported"))
    case .data(let data):
      if let totals = usageTotals(data) {
        usage.source = totals
        guard let staged = try copyFile(src.usage, rel: "usage.json", stage: stage, keepData: true) else {
          throw failure("usage.json changed while importing")
        }
        usage.imported = usageTotals(staged)
        guard usage.imported == usage.source else { throw failure("staged usage totals differ from the source") }
      } else {
        stage.skipped.append(Skipped(path: src.usage.path, reason: "usage.json unreadable or not schema_version 1; not imported"))
      }
    }

    // The legacy text vocab list.
    let legacyVocab = src.root.appendingPathComponent("vocab")
    var hasLegacyVocab = false
    if lstatMode(legacyVocab) != nil,
       try copyFile(legacyVocab, rel: "vocab", stage: stage, keepData: false) != nil {
      hasLegacyVocab = true
    }

    // Vocabulary and its backups.
    let vocab = src.root.appendingPathComponent("vocabulary.json")
    var vocabulary = false
    if lstatMode(vocab) != nil, let data = try copyFile(vocab, rel: "vocabulary.json", stage: stage, keepData: true) {
      vocabulary = true
      if !parsesAsObject(data) {
        stage.skipped.append(Skipped(path: vocab.path, reason: "vocabulary.json is not valid JSON (copied as-is)"))
      }
    }
    let backups = src.root.appendingPathComponent("vocabulary-backups", isDirectory: true)
    if isDirectory(backups) {
      counts.vocabulary_backups = try copyTree(backups, rel: "vocabulary-backups", stage: stage)
    }

    // Take ids the CLI already saved.
    let ids = try legacyTakeIDs(src.root, stage: stage)
    try writeStaged(try JSONSerialization.data(withJSONObject: ids, options: [.prettyPrinted]),
                    rel: legacyTakeIDsName, stage: stage)

    // Settings: config.toml -> settings.json, only the keys the app uses.
    let settingsOutcome = try importSettings(src.root, stage: stage)

    // Every staged copy was size-checked against its source and fsynced as it
    // was written; usage totals were re-read from the staged bytes above.
    try syncDirectory(staging)
    try checkpoint(.staged)

    // Promote. The journal gets a line per file only after its move succeeds.
    let journal = try Journal(dest.appendingPathComponent(journalName))
    defer { journal.close() }
    try promote(staging, into: dest, rel: "", stage: stage, journal: journal, checkpoint: checkpoint)
    try checkpoint(.moved)

    let receipt = Receipt(imported_at: iso8601(now), source_root: src.root.path, counts: counts, usage: usage,
                          vocabulary: vocabulary, legacy_vocab: hasLegacyVocab, legacy_take_ids: ids.count, skipped: stage.skipped + kept,
                          settings: settingsOutcome)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try DataFiles.replace(dest.appendingPathComponent(receiptName), with: try encoder.encode(receipt))
    unlink(dest.appendingPathComponent(journalName).path)
    try? removeStaging(staging)
    try? syncDirectory(dest)  // receipt already durable via replace
    return .imported(receipt)
  }

  // MARK: Checks

  static let appEntries = ["history", "history/inline-debug", "usage.json", "vocabulary.json", "vocab",
                           "vocabulary-backups", legacyTakeIDsName, stagingName, journalName]

  /// Newer app data that an import must never merge over.
  /// Stages settings.json from the CLI's config. "imported" or "defaults".
  static func importSettings(_ root: URL, stage: Stage) throws -> String {
    let result = LegacySettings.convert(configDir: root)
    for problem in result.problems {
      stage.skipped.append(Skipped(path: problem.path, reason: problem.reason))
    }
    guard let conversion = result.conversion, let source = result.source else {
      guard !result.problems.isEmpty else { return "defaults" }
      // The CLI had settings but none convert: defaults, but never autosend
      // on a guess; the app warns until a setting is changed.
      var safe = AppSettings()
      safe.inline.autosend = false
      safe.importWarning = "the CLI's config.toml could not be converted; using defaults"
      try writeStaged(try SettingsStore.encode(safe, over: [:]), rel: AppSettings.fileName, stage: stage)
      return "defaults_no_autosend"
    }
    for item in conversion.skipped {
      stage.skipped.append(Skipped(path: source.path + " " + item.key, reason: item.reason))
    }
    let data = try SettingsStore.encode(conversion.settings, over: [:])
    try writeStaged(data, rel: AppSettings.fileName, stage: stage)
    return "imported"
  }

  static func existingAppData(_ dest: URL) -> String? {
    let history = dest.appendingPathComponent("history", isDirectory: true)
    if let names = try? FileManager.default.contentsOfDirectory(atPath: history.path),
       names.contains(where: { $0.hasSuffix(".json") }) {
      return "the app already has history in \(history.path)"
    }
    if countFiles(history.appendingPathComponent("inline-debug")) > 0 {
      return "the app already has a debug archive in \(history.path)"
    }
    for name in ["usage.json", "vocabulary.json", "vocab", legacyTakeIDsName, AppSettings.fileName]
    where lstatMode(dest.appendingPathComponent(name)) != nil {
      return "the app already has \(name)"
    }
    if countFiles(dest.appendingPathComponent("vocabulary-backups")) > 0 {
      return "the app already has vocabulary backups"
    }
    return nil
  }

  /// Any path the import creates or cleans must not be a symlink.
  static func symlinkIssue(_ dest: URL) -> String? {
    for rel in appEntries {
      if let mode = lstatMode(dest.appendingPathComponent(rel)), mode == S_IFLNK {
        return "\(dest.appendingPathComponent(rel).path) is a symlink"
      }
    }
    return nil
  }

  /// The app folder and the CLI folder (or its usage file) must not contain one another.
  static func overlapIssue(_ src: Source, _ dest: URL) -> String? {
    guard let d = realPath(dest) else { return "cannot resolve \(dest.path)" }
    for url in [src.root, src.usage] {
      guard let s = realPath(url) else { continue }
      if s == d || s.hasPrefix(d + "/") || d.hasPrefix(s + "/") {
        return "the app folder \(d) overlaps the CLI data at \(s)"
      }
    }
    return nil
  }

  static func realPath(_ url: URL) -> String? {
    guard let p = Darwin.realpath(url.path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
  }

  static func usageTotals(_ data: Data) -> UsageTotals? {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          int(obj["schema_version"]) == 1,
          let deliveries = obj["delivered_dictations"] as? [String: Any],
          let count = int(deliveries["count"]), let words = int(obj["processed_words"]),
          let ms = int(obj["recording_duration_ms"]) else { return nil }
    return UsageTotals(count: count, processed_words: words, recording_duration_ms: ms)
  }

  /// A non-negative JSON integer: not a bool, not a float (1.5 or 1.0).
  static func int(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(n), n.int64Value >= 0, n.int64Value <= Int64(Int.max) else { return nil }
    return n.intValue
  }

  static func parsesAsObject(_ data: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil
  }

  static func legacyTakeIDs(_ root: URL, stage: Stage) throws -> [String] {
    var ids = Set<String>()
    let cache = root.appendingPathComponent(".cache", isDirectory: true)
    for name in ledgerNames {
      let url = cache.appendingPathComponent(name)
      switch try readRegular(url) {
      case .missing: continue
      case .notRegular: stage.skipped.append(Skipped(path: url.path, reason: "take ledger is not a regular file"))
      case .data(let data):
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
          let id = line.trimmingCharacters(in: .whitespaces)
          if !id.isEmpty { ids.insert(id) }
        }
      }
    }
    return ids.sorted()
  }

  // MARK: Reading the source

  enum Read { case missing, notRegular, data(Data) }

  /// Opens without following a final symlink and without blocking on a FIFO;
  /// returns the descriptor only for a regular file.
  static func openRegular(_ url: URL) throws -> (Int32, stat)? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return nil }
      if errno == ELOOP || errno == ENXIO || errno == EOPNOTSUPP { return (-1, stat()) }
      throw DataFiles.posix("cannot open", url.path)
    }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return (-1, stat()) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    return (fd, st)
  }

  static func readRegular(_ url: URL) throws -> Read {
    guard let (fd, _) = try openRegular(url) else { return .missing }
    guard fd >= 0 else { return .notRegular }
    defer { close(fd) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let n = read(fd, &buffer, buffer.count)
      if n < 0 { if errno == EINTR { continue }; throw DataFiles.posix("cannot read", url.path) }
      if n == 0 { break }
      data.append(buffer, count: n)
    }
    return .data(data)
  }

  // MARK: Writing private copies

  struct Identity: Equatable {
    var dev: Int64, ino: UInt64, size: Int64, mtimeSec: Int64, mtimeNsec: Int64
    init(_ st: stat) {
      dev = Int64(st.st_dev); ino = UInt64(st.st_ino); size = Int64(st.st_size)
      mtimeSec = Int64(st.st_mtimespec.tv_sec); mtimeNsec = Int64(st.st_mtimespec.tv_nsec)
    }
    init?(fields: [Substring]) {
      guard fields.count == 5, let a = Int64(fields[0]), let b = UInt64(fields[1]), let c = Int64(fields[2]),
            let d = Int64(fields[3]), let e = Int64(fields[4]) else { return nil }
      dev = a; ino = b; size = c; mtimeSec = d; mtimeNsec = e
    }
    var fields: String { "\(dev)\t\(ino)\t\(size)\t\(mtimeSec)\t\(mtimeNsec)" }
  }

  static func safeName(_ name: String) -> Bool {
    !name.contains("\n") && !name.contains("\t") && !name.contains("\r")
  }

  /// Copies a regular file's bytes into a new 0600 file under the stage,
  /// fsyncs it and gives it the source's times. Returns nil (and records it as
  /// skipped) for anything that isn't a regular file. With `keepData`, returns
  /// the bytes so callers can parse them without a second read.
  @discardableResult
  static func copyFile(_ from: URL, rel: String, stage: Stage, keepData: Bool) throws -> Data? {
    guard safeName(rel) else {
      stage.skipped.append(Skipped(path: from.path, reason: "name contains a control character")); return nil
    }
    guard let (src, st) = try openRegular(from) else { return nil }
    guard src >= 0 else {
      stage.skipped.append(Skipped(path: from.path, reason: "not a regular file")); return nil
    }
    defer { close(src) }
    let to = stage.root.appendingPathComponent(rel)
    let dst = open(to.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard dst >= 0 else { throw DataFiles.posix("cannot create", to.path) }
    defer { close(dst) }
    _ = fchmod(dst, 0o600)
    var kept = Data()
    var total: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let n = read(src, &buffer, buffer.count)
      if n < 0 { if errno == EINTR { continue }; throw DataFiles.posix("cannot read", from.path) }
      if n == 0 { break }
      var off = 0
      while off < n {
        let w = buffer.withUnsafeBytes { write(dst, $0.baseAddress! + off, n - off) }
        if w < 0 { if errno == EINTR { continue }; throw DataFiles.posix("cannot write", to.path) }
        off += w
      }
      total += Int64(n)
      if keepData { kept.append(buffer, count: n) }
    }
    guard total == Int64(st.st_size) else { throw failure("\(from.path) changed size while importing") }
    var times = [st.st_atimespec, st.st_mtimespec]
    guard futimens(dst, &times) == 0, fsync(dst) == 0 else { throw DataFiles.posix("cannot finish", to.path) }
    var out = stat()
    guard fstat(dst, &out) == 0 else { throw DataFiles.posix("cannot stat", to.path) }
    stage.identities[rel] = Identity(out)
    return keepData ? kept : Data()
  }

  /// A file the import writes itself (legacy take ids).
  static func writeStaged(_ data: Data, rel: String, stage: Stage) throws {
    let to = stage.root.appendingPathComponent(rel)
    let fd = open(to.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DataFiles.posix("cannot create", to.path) }
    defer { close(fd) }
    let ok = data.withUnsafeBytes { raw -> Bool in
      var off = 0
      while off < raw.count {
        let w = write(fd, raw.baseAddress! + off, raw.count - off)
        if w < 0 { if errno == EINTR { continue }; return false }
        off += w
      }
      return true
    }
    var st = stat()
    guard ok, fsync(fd) == 0, fstat(fd, &st) == 0 else { throw DataFiles.posix("cannot write", to.path) }
    stage.identities[rel] = Identity(st)
  }

  static func makePrivateDirectory(_ url: URL) throws {
    if mkdir(url.path, 0o700) != 0 {
      guard errno == EEXIST, lstatMode(url) == S_IFDIR else { throw DataFiles.posix("cannot create directory", url.path) }
    }
    _ = chmod(url.path, 0o700)
  }

  /// Copies regular files under `from` (recursively, never following
  /// symlinks); skips anything else. One walk; returns the files copied.
  static func copyTree(_ from: URL, rel: String, stage: Stage) throws -> Int {
    let to = stage.root.appendingPathComponent(rel)
    try makePrivateDirectory(to)
    var n = 0
    for name in try FileManager.default.contentsOfDirectory(atPath: from.path).sorted() {
      let s = from.appendingPathComponent(name)
      guard safeName(name) else {
        stage.skipped.append(Skipped(path: s.path, reason: "name contains a control character")); continue
      }
      switch lstatMode(s) {
      case S_IFDIR: n += try copyTree(s, rel: rel + "/" + name, stage: stage)
      case S_IFREG: if try copyFile(s, rel: rel + "/" + name, stage: stage, keepData: false) != nil { n += 1 }
      default: stage.skipped.append(Skipped(path: s.path, reason: "not a regular file"))
      }
    }
    try syncDirectory(to)
    try copyTimes(from, to)
    return n
  }

  /// Sets `to`'s times to `from`'s, to the nanosecond (retention uses mtime).
  static func copyTimes(_ from: URL, _ to: URL) throws {
    var st = stat()
    guard stat(from.path, &st) == 0 else { throw DataFiles.posix("cannot stat", from.path) }
    var times = [st.st_atimespec, st.st_mtimespec]
    guard utimensat(AT_FDCWD, to.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw DataFiles.posix("cannot set times on", to.path)
    }
  }

  // MARK: Promotion and the journal

  /// Append-only, one line per promoted file: `dev ino size mtime_s mtime_ns path`
  /// (tab-separated, path relative to the app folder), fsynced per item.
  final class Journal {
    let fd: Int32
    init(_ url: URL) throws {
      fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw DataFiles.posix("cannot create", url.path) }
      guard fsync(fd) == 0 else { throw DataFiles.posix("cannot sync", url.path) }
      try syncDirectory(url.deletingLastPathComponent())
    }
    func append(_ lines: [String]) throws {
      guard !lines.isEmpty else { return }
      let data = Data((lines.joined(separator: "\n") + "\n").utf8)
      let ok = data.withUnsafeBytes { raw -> Bool in
        var off = 0
        while off < raw.count {
          let w = write(fd, raw.baseAddress! + off, raw.count - off)
          if w < 0 { if errno == EINTR { continue }; return false }
          off += w
        }
        return true
      }
      guard ok, fsync(fd) == 0 else { throw failure("cannot write the import journal") }
    }
    func close() { Darwin.close(fd) }
  }

  /// Moves staged entries into `dest`: a whole entry when it's absent there,
  /// else (both real directories, e.g. an empty `history/` a writer made)
  /// entry by entry. Never replaces anything, never follows a symlink.
  static func promote(_ from: URL, into dest: URL, rel: String, stage: Stage, journal: Journal,
                      checkpoint: (Checkpoint) throws -> Void) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: from.path).sorted() {
      let s = from.appendingPathComponent(name), d = dest.appendingPathComponent(name)
      let itemRel = rel.isEmpty ? name : rel + "/" + name
      switch lstatMode(d) {
      case nil:
        guard rename(s.path, d.path) == 0 else { throw DataFiles.posix("cannot move into place", d.path) }
        let prefix = itemRel + "/"
        let lines = stage.identities
          .filter { $0.key == itemRel || $0.key.hasPrefix(prefix) }
          .sorted { $0.key < $1.key }
          .map { "\($0.value.fields)\t\($0.key)" }
        try journal.append(lines)
        try checkpoint(.promoted(itemRel))
      case S_IFDIR where lstatMode(s) == S_IFDIR:
        try promote(s, into: d, rel: itemRel, stage: stage, journal: journal, checkpoint: checkpoint)
      default:
        throw failure("refusing to replace \(d.path)")
      }
    }
    try syncDirectory(dest)
  }

  /// Undoes a crashed run's promotions: deletes a journaled file only when it
  /// is still the very copy the import made (same dev, inode, size, mtime) and
  /// no component of its path is a symlink. Anything else is kept and
  /// returned. If a deletion fails the journal stays and this throws.
  static func rollBackJournal(_ dest: URL) throws -> [Skipped] {
    let url = dest.appendingPathComponent(journalName)
    guard case .data(let data) = try readRegular(url) else {
      if lstatMode(url) != nil { throw failure("\(url.path) is not a regular file") }
      return []
    }
    var kept: [Skipped] = []
    var dirs = Set<String>()
    var failed = false
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
      guard parts.count == 6, let identity = Identity(fields: Array(parts[0..<5])) else { continue }
      let rel = String(parts[5])
      let comps = rel.split(separator: "/", omittingEmptySubsequences: false)
      guard !rel.hasPrefix("/"), !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { continue }
      let target = dest.appendingPathComponent(rel)
      // Every parent under dest must be a real directory.
      var parent = dest
      var safe = true
      for c in comps.dropLast() {
        parent = parent.appendingPathComponent(String(c))
        if let m = lstatMode(parent), m != S_IFDIR { safe = false; break }
      }
      guard safe else { kept.append(Skipped(path: target.path, reason: "path crosses a symlink; kept")); continue }
      var st = stat()
      guard lstat(target.path, &st) == 0 else { continue }
      guard (st.st_mode & S_IFMT) == S_IFREG, Identity(st) == identity else {
        kept.append(Skipped(path: target.path, reason: "changed since the interrupted import; kept")); continue
      }
      if unlink(target.path) != 0 && errno != ENOENT { failed = true }
      var p = comps.dropLast()
      while !p.isEmpty { dirs.insert(p.joined(separator: "/")); p = p.dropLast() }
    }
    for dir in dirs.sorted(by: { $0.count > $1.count }) { rmdir(dest.appendingPathComponent(dir).path) }
    guard !failed else { throw failure("could not undo an interrupted import; journal kept at \(url.path)") }
    unlink(url.path)
    try syncDirectory(dest)
    return kept
  }

  /// Staging is ours: a symlink there is only unlinked, never followed.
  static func removeStaging(_ staging: URL) throws {
    switch lstatMode(staging) {
    case nil: return
    case S_IFDIR: try FileManager.default.removeItem(at: staging)
    default: unlink(staging.path)
    }
  }

  // MARK: File helpers

  static func lstatMode(_ url: URL) -> mode_t? {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return nil }
    return st.st_mode & S_IFMT
  }

  static func isDirectory(_ url: URL) -> Bool { lstatMode(url) == S_IFDIR }

  /// For the source root and its history folder, which may be symlinked.
  static func isDirectoryFollowing(_ url: URL) -> Bool {
    var st = stat()
    return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
  }

  /// Regular files under a real directory, never following symlinks.
  static func countFiles(_ dir: URL) -> Int {
    guard isDirectory(dir), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
    var n = 0
    for name in names {
      let u = dir.appendingPathComponent(name)
      switch lstatMode(u) {
      case S_IFDIR: n += countFiles(u)
      case S_IFREG: n += 1
      default: break
      }
    }
    return n
  }

  /// Test seam: tests swap in a failing sync for one task only.
  @TaskLocal static var syncOverride: DataFiles.SyncDirectory?
  static func syncDirectory(_ url: URL) throws { try (syncOverride ?? DataFiles.syncDirectory)(url) }

  static func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
  }
}
