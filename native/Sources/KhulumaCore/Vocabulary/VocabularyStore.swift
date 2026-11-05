import CryptoKit
import Darwin
import Foundation

/// The app's vocabulary document in its own folder: `vocab-sheet show`,
/// `validate` and `save` ported from `bin/khuluma-lib/vocabulary.py`.
///
/// `vocabulary.json` is the document; before it exists, the retained text
/// `vocab` file (plus the default fillers) is shown instead. A revision is the
/// SHA-256 of the source bytes (tagged by kind); callers treat it as opaque.
/// Saves run under `flock(.vocabulary.lock)`, refuse a stale revision and any
/// symbolic link, keep the exact previous bytes in `vocabulary-backups/`, and
/// publish with a temp file and rename. Files are 0600, folders 0700.
public struct VocabularyStore: Sendable {
  public let root: URL
  public var lockTimeout: TimeInterval = 10
  /// Makes a created or renamed entry durable; injectable for tests.
  public var syncDirectory: DataFiles.SyncDirectory = DataFiles.syncDirectory

  public init(root: URL) { self.root = root }

  private var sheetURL: URL { root.appendingPathComponent("vocabulary.json") }
  private var legacyURL: URL { root.appendingPathComponent("vocab") }
  private var lockURL: URL { root.appendingPathComponent(".vocabulary.lock") }
  private var backupsURL: URL { root.appendingPathComponent("vocabulary-backups", isDirectory: true) }

  public static let defaultFillers = VocabularySheet.defaults.fillers

  static func invalid(_ message: String) -> VocabularySheet.Invalid { .document(message) }

  public func validate(_ data: Data) throws -> VocabularySheet { try VocabularySheet.decode(data) }

  public func show() throws -> VocabularySnapshot { try state() }

  /// Replaces the document if `snapshot.revision` is still current. An
  /// identical document changes nothing (no backup, no write).
  public func save(_ snapshot: VocabularySnapshot) throws -> VocabularySnapshot {
    let document = try snapshot.document.validated()
    let encoded = try document.encoded()
    try Self.makeDirectory(root)
    if Self.isSymlink(lockURL) { throw Self.invalid("The vocabulary lock must not be a symbolic link.") }
    return try DataFiles.withLock(lockURL, timeout: lockTimeout) {
      chmod(lockURL.path, 0o600)
      let current = try state()
      guard snapshot.revision == current.revision else {
        throw Self.invalid("Vocabulary changed on disk. Reload it before saving; your draft has been kept.")
      }
      let exists = FileManager.default.fileExists(atPath: sheetURL.path)
      if current.document != document || !exists {
        if exists {
          if Self.isSymlink(backupsURL) { throw Self.invalid("The vocabulary backup folder must not be a symbolic link.") }
          let created = !FileManager.default.fileExists(atPath: backupsURL.path)
          try Self.makeDirectory(backupsURL)
          let backup = backupsURL.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
          try Self.writeNew(try Data(contentsOf: sheetURL), to: backup)
          // The backup must be on disk before the original is replaced; a
          // failed sync aborts the save with vocabulary.json untouched.
          try syncDirectory(backupsURL)
          if created { try syncDirectory(root) }
        }
        try DataFiles.replace(sheetURL, with: encoded, syncDirectory: syncDirectory)
      }
      return try state()
    }
  }

  // MARK: - Reading

  func state() throws -> VocabularySnapshot {
    if Self.isSymlink(sheetURL) { throw Self.invalid("vocabulary.json must be a regular file, not a symbolic link.") }
    let tag: String
    let raw: Data
    let document: VocabularySheet
    if FileManager.default.fileExists(atPath: sheetURL.path) {
      raw = try Self.readBounded(sheetURL)
      document = try VocabularySheet.decode(raw)
      tag = "json"
    } else {
      raw = FileManager.default.fileExists(atPath: legacyURL.path) ? try Self.readBounded(legacyURL) : Data()
      tag = "text"
      document = try Self.legacyDocument(raw)
    }
    let digest = SHA256.hash(data: Data((tag + "\0").utf8) + raw)
    return VocabularySnapshot(document: document, revision: digest.map { String(format: "%02x", $0) }.joined())
  }

  /// The old `vocab` text: `heard -> write`, `heard → write` or
  /// `heard::write` lines, `#` comments. Conflicts and bad lines are errors.
  static func legacyDocument(_ raw: Data) throws -> VocabularySheet {
    guard let text = String(data: raw, encoding: .utf8) else {
      throw invalid("The existing vocab is not valid UTF-8. Correct it before opening Vocabulary.")
    }
    var sheet = VocabularySheet.defaults
    var seen: [String: String] = [:]
    for rawLine in splitLines(text) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }
      var pair: [String]
      if let range = line.range(of: "::") {
        pair = [String(line[..<range.lowerBound]), String(line[range.upperBound...])]
      } else if let range = line.range(of: "->") ?? line.range(of: "→") {
        // The earliest of the two arrows, as the CLI's regex finds it.
        let other = line.range(of: "→")
        let first = other.map { $0.lowerBound < range.lowerBound ? $0 : range } ?? range
        pair = [String(line[..<first.lowerBound]), String(line[first.upperBound...])]
      } else {
        pair = [line]
      }
      guard pair.count == 2,
            pair.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw invalid("The existing vocab contains an invalid line. Correct it before opening Vocabulary.")
      }
      let heard = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let write = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let key = heard.precomposedStringWithCanonicalMapping.lowercased()
      if let existing = seen[key] {
        if existing != write { throw invalid("Existing vocab has conflicting replacements for “\(heard)”.") }
        continue
      }
      seen[key] = write
      sheet.words.append(.init(heard: heard, write: write))
    }
    return try sheet.validated()
  }

  /// Python's `str.splitlines()`: \n, \r, \r\n, \v, \f, FS/GS/RS, NEL, LS, PS.
  static func splitLines(_ text: String) -> [String] {
    let breaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var previousWasCR = false
    for scalar in text.unicodeScalars {
      if previousWasCR, scalar.value == 0x0A { previousWasCR = false; continue }
      previousWasCR = false
      if breaks.contains(scalar.value) {
        lines.append(String(current))
        current = String.UnicodeScalarView()
        previousWasCR = scalar.value == 0x0D
      } else {
        current.append(scalar)
      }
    }
    if !current.isEmpty { lines.append(String(current)) }
    return lines
  }

  // MARK: - Files

  static func isSymlink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }

  static func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
  }

  static func readBounded(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: VocabularySheet.maximumBytes + 1) ?? Data()
    guard data.count <= VocabularySheet.maximumBytes else {
      throw invalid("Choose a vocabulary JSON file smaller than 1 MB.")
    }
    return data
  }

  /// A new 0600 file that must not exist yet, fsynced.
  static func writeNew(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DataFiles.posix("cannot create", url.path) }
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
      unlink(url.path)
      throw DataFiles.posix("cannot write", url.path, code)
    }
  }
}
