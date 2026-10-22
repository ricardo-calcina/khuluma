import Darwin
import Foundation

/// Marks one Khuluma take as in progress, from before capture starts until
/// it is delivered, fails or is cancelled. The CLI's idle check reads it
/// (so a daemon upgrade never lands mid-take): a file in the processing dir
/// named `inline-khuluma-<id>` whose first line is `pid=<Khuluma's pid>`, like
/// the CLI's own markers.
public final class TakeMarker: @unchecked Sendable {
  public enum Phase: String, Sendable {
    /// Capturing audio.
    case recording
    /// Stopped, waiting for earlier takes or the settings.
    case queued
    /// Transcribing, cleaning up or delivering in Khuluma.
    case processing
    /// Handed to `khuluma inline process`, which has its own marker;
    /// still busy for the idle check.
    case cli
  }

  public static let prefix = "inline-khuluma-"
  /// The CLI's processing dir when KHULUMA_PROCESSING_DIR is unset.
  public static var defaultDirectory: String {
    AppRuntimePaths.isolated ? AppRuntimePaths.temporary.appendingPathComponent("processing").path : "/tmp/khuluma-processing"
  }

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

  /// Written to a dot-file (which the CLI's globs skip) and
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

  /// Removes markers a previous Khuluma left behind (crash, force quit), so
  /// a reused pid can't keep the CLI waiting for a take that will never
  /// finish. Keeps this process's markers and those of another running
  /// Khuluma. Returns the names removed.
  @discardableResult
  public static func removeStale(directory: String, ownPid: Int32 = getpid(),
                                 isKhuluma: (Int32) -> Bool = TakeMarker.isRunningKhuluma) -> [String] {
    let dir = URL(fileURLWithPath: directory, isDirectory: true)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
    var removedNames: [String] = []
    for name in names where name.hasPrefix(prefix) || name.hasPrefix(LegacyNames.markerPrefix) {
      let url = dir.appendingPathComponent(name)
      let firstLine = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first ?? ""
      let pid = firstLine.hasPrefix("pid=") ? Int32(firstLine.dropFirst(4)) : nil
      if let pid, pid == ownPid || isKhuluma(pid) { continue }
      try? FileManager.default.removeItem(at: url)
      removedNames.append(name)
    }
    return removedNames
  }

  /// True when `pid` is a live process whose executable is named Khuluma
  /// (or Lowkey, from before the rename).
  public static func isRunningKhuluma(_ pid: Int32) -> Bool {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
    let name = URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    return name == "Khuluma" || name == LegacyNames.executable
  }
}
