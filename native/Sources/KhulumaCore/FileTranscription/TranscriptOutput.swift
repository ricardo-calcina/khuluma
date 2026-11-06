import Darwin
import Foundation

/// Where a file transcript goes and how it's written, as the CLI does it:
/// never over an existing file without `--force`, never over the input, and
/// never a partial file (a temp file beside the destination, then an atomic
/// exclusive rename).
public enum TranscriptOutput {
  public struct Failure: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }

  /// `transcribe_file_destination`: nil means stdout.
  public static func destination(for input: String, output: String?, beside: Bool, ext: String) -> String? {
    if let output { return output }
    guard beside else { return nil }
    return besidePath(for: input, ext: ext)
  }

  /// `<dir>/<name>.<ext>`, `<name>` without its last extension (bash's
  /// `[[ $name == ?*.* ]] && name=${name%.*}`: a leading dot alone isn't one).
  public static func besidePath(for input: String, ext: String) -> String {
    let directory = (input as NSString).deletingLastPathComponent
    var name = (input as NSString).lastPathComponent
    if let dot = name.lastIndex(of: "."), dot > name.startIndex { name = String(name[..<dot]) }
    let file = "\(name).\(ext)"
    return directory.isEmpty ? file : (directory as NSString).appendingPathComponent(file)
  }

  /// The checks made before transcribing, so an existing output fails fast.
  public static func precheck(destination: String, input: String, force: Bool) throws {
    if sameFile(destination, input) { throw Failure("refusing to overwrite the input file: \(input)") }
    if exists(destination) && !force { throw Failure(existsMessage(destination)) }
  }

  public static func existsMessage(_ path: String) -> String { "output exists (use --force to overwrite): \(path)" }

  /// `transcribe_file_write_output`: `content` plus a newline.
  public static func write(_ content: String, to destination: String, force: Bool) throws {
    if exists(destination) && !force { throw Failure(existsMessage(destination)) }
    let directory = ((destination as NSString).deletingLastPathComponent as String).isEmpty
      ? "." : (destination as NSString).deletingLastPathComponent
    do {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    } catch {
      throw Failure("cannot create output directory: \(directory)")
    }
    var template = Array((directory as NSString).appendingPathComponent(".khuluma-transcript.XXXXXX").utf8CString)
    let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    guard fd >= 0 else { throw Failure("cannot write output: \(destination)") }
    let temp = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    PendingOutputs.shared.add(temp)
    defer {
      unlink(temp)
      PendingOutputs.shared.remove(temp)
    }
    let mask = umask(0)
    umask(mask)
    fchmod(fd, 0o666 & ~mask)
    let data = Array((content + "\n").utf8)
    var offset = 0
    var ok = true
    while offset < data.count {
      let written = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written < 0 { if errno == EINTR { continue }; ok = false; break }
      offset += written
    }
    if ok && fsync(fd) != 0 { ok = false }
    if close(fd) != 0 { ok = false }
    guard ok else { throw Failure("cannot write output: \(destination)") }

    if force {
      guard rename(temp, destination) == 0 else { throw Failure("cannot write output: \(destination)") }
      return
    }
    // Refuses atomically when the name exists, so a file that appeared after
    // the check is never replaced.
    if renamex_np(temp, destination, UInt32(RENAME_EXCL)) == 0 { return }
    let reason = errno
    if reason == EEXIST { throw Failure(existsMessage(destination)) }
    if reason == ENOTSUP || reason == EINVAL {
      // No exclusive rename here (exFAT/FAT recorders): link(2) also refuses
      // an existing name. Never a plain rename without --force.
      if link(temp, destination) == 0 { return }
      if errno == EEXIST { throw Failure(existsMessage(destination)) }
      throw Failure("cannot write \(destination) safely")
    }
    throw Failure("cannot write output: \(destination)")
  }

  /// The Quick Action's naming: `destination`, else `<name>-2.<ext>`,
  /// `-3`, ... the first free name. Each name is claimed by the exclusive
  /// rename in `write`, so two runs never pick the same one or overwrite.
  /// Returns the path written.
  @discardableResult
  public static func writeFirstFree(_ content: String, to destination: String, limit: Int = 1000) throws -> String {
    let ext = (destination as NSString).pathExtension
    let stem = (destination as NSString).deletingPathExtension
    for n in 1...limit {
      let candidate = n == 1 ? destination : "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
      do {
        try write(content, to: candidate, force: false)
        return candidate
      } catch let failure as Failure where failure.message == existsMessage(candidate) {
        continue
      }
    }
    throw Failure("no free name for \(destination)")
  }

  static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  /// bash `-ef`: both exist and are the same inode.
  static func sameFile(_ a: String, _ b: String) -> Bool {
    var x = stat(), y = stat()
    return stat(a, &x) == 0 && stat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
  }

  /// One `--format json` line, byte for byte what the CLI's Python printed
  /// (`json.dumps(..., ensure_ascii=False)`, its key order and separators).
  public static func jsonLine(file: String, transcript: FileTranscriber.Transcript) -> String {
    "{\"file\": \(jsonString(file)), \"text\": \(jsonString(transcript.text)), "
      + "\"audio_duration_ms\": \(transcript.audioDurationMs), \"processing_ms\": \(transcript.processingMs), "
      + "\"model\": \(jsonString(transcript.model)), \"engine\": \(jsonString(transcript.engine))}"
  }

  static func jsonString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}

/// Temp outputs being written, so an interrupt can remove them.
public final class PendingOutputs: @unchecked Sendable {
  public static let shared = PendingOutputs()
  private let lock = NSLock()
  private var paths: Set<String> = []

  func add(_ path: String) { lock.withLock { _ = paths.insert(path) } }
  func remove(_ path: String) { lock.withLock { _ = paths.remove(path) } }

  /// Removes every pending temp file (from a signal handler's queue).
  public func removeAll() {
    for path in lock.withLock({ paths }) { unlink(path) }
  }
}
