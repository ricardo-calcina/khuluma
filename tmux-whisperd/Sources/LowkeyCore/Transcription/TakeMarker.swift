import Darwin
import Foundation

/// Marks one Lowkey take as in progress, from before capture starts until
/// it is delivered, fails or is cancelled. The CLI's idle check reads it
/// (so a daemon upgrade never lands mid-take) and SwiftBar shows the
/// processing part: a file in the processing dir named `inline-lowkey-<id>`
/// whose first line is `pid=<Lowkey's pid>`, like the CLI's own markers.
public final class TakeMarker: @unchecked Sendable {
  public enum Phase: String, Sendable {
    /// Capturing audio.
    case recording
    /// Stopped, waiting for earlier takes or the settings.
    case queued
    /// Transcribing, cleaning up or delivering in Lowkey.
    case processing
    /// Handed to `tmux-whisper inline process`, which has its own marker;
    /// still busy for the idle check, not counted twice by SwiftBar.
    case cli
  }

  public static let prefix = "inline-lowkey-"
  /// The CLI's processing dir when DICTATE_PROCESSING_DIR is unset.
  public static let defaultDirectory = "/tmp/dictate-processing"

  public let url: URL
  private let pid: Int32
  private let takeId: String
  private let startedAt: Int
  private let lock = NSLock()
  private var removed = false
  public private(set) var phase: Phase

  private init(url: URL, pid: Int32, takeId: String, phase: Phase) {
    self.url = url
    self.pid = pid
    self.takeId = takeId
    self.phase = phase
    self.startedAt = Int(Date().timeIntervalSince1970)
  }

  /// Publishes a marker, or nil if it can't be written (the take goes on;
  /// only the idle check loses sight of it).
  public static func create(directory: String, takeId: String, phase: Phase,
                            pid: Int32 = getpid()) -> TakeMarker? {
    let dir = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safeId = String(takeId.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
    let marker = TakeMarker(url: dir.appendingPathComponent(prefix + safeId), pid: pid, takeId: safeId, phase: phase)
    return marker.write(phase) ? marker : nil
  }

  /// Moves to a new phase. A no-op once removed, so a late update never
  /// brings back a finished take.
  public func update(_ phase: Phase) {
    lock.lock()
    defer { lock.unlock() }
    guard !removed, phase != self.phase else { return }
    if writeLocked(phase) { self.phase = phase }
  }

  public func remove() {
    lock.lock()
    defer { lock.unlock() }
    guard !removed else { return }
    removed = true
    try? FileManager.default.removeItem(at: url)
  }

  private func write(_ phase: Phase) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return writeLocked(phase)
  }

  /// Written to a dot-file (which the CLI's and SwiftBar's globs skip) and
  /// renamed into place, so readers never see a half-written marker.
  private func writeLocked(_ phase: Phase) -> Bool {
    let body = "pid=\(pid)\nkind=inline\nsession_id=\(takeId)\nphase=\(phase.rawValue)\nstarted_at=\(startedAt)\n"
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: temp.path, contents: Data(body.utf8)) else { return false }
    guard rename(temp.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temp)
      return false
    }
    return true
  }

  /// Removes markers a previous Lowkey left behind (crash, force quit), so
  /// a reused pid can't keep the CLI waiting for a take that will never
  /// finish. Keeps this process's markers and those of another running
  /// Lowkey. Returns the names removed.
  @discardableResult
  public static func removeStale(directory: String, ownPid: Int32 = getpid(),
                                 isLowkey: (Int32) -> Bool = TakeMarker.isRunningLowkey) -> [String] {
    let dir = URL(fileURLWithPath: directory, isDirectory: true)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    var removedNames: [String] = []
    for name in names where name.hasPrefix(prefix) {
      let url = dir.appendingPathComponent(name)
      let firstLine = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first ?? ""
      let pid = firstLine.hasPrefix("pid=") ? Int32(firstLine.dropFirst(4)) : nil
      if let pid, pid == ownPid || isLowkey(pid) { continue }
      try? FileManager.default.removeItem(at: url)
      removedNames.append(name)
    }
    return removedNames
  }

  /// True when `pid` is a live process whose executable is named Lowkey.
  public static func isRunningLowkey(_ pid: Int32) -> Bool {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
    return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "Lowkey"
  }
}
