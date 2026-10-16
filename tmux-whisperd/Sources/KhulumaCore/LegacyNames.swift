import Foundation

/// The app was called Lowkey before Khuluma. Its folders move to the new
/// names once, at launch, before anything reads or writes them: the log,
/// Application Support (pending records and recovered audio) and the
/// timed-out takes kept for Retry. Nothing is ever overwritten: when both
/// names exist, files move across one by one and a name already taken stays
/// where it was.
public enum LegacyNames {
  /// The executable name of builds from before the rename, still running
  /// (or leaving take markers) while the new build takes over.
  public static let executable = "Lowkey"
  /// Take markers written by those builds.
  public static let markerPrefix = "inline-lowkey-"

  public struct Move: Equatable, Sendable {
    public let from: URL
    public let to: URL
  }

  /// The old and new folders, under `home` and the temporary directory.
  public static func moves(home: URL, temporary: URL) -> [Move] {
    [
      Move(from: home.appendingPathComponent("Library/Logs/Lowkey", isDirectory: true),
           to: home.appendingPathComponent("Library/Logs/Khuluma", isDirectory: true)),
      Move(from: home.appendingPathComponent("Library/Application Support/Lowkey", isDirectory: true),
           to: home.appendingPathComponent("Library/Application Support/Khuluma", isDirectory: true)),
      Move(from: temporary.appendingPathComponent("lowkey-timed-out", isDirectory: true),
           to: temporary.appendingPathComponent("khuluma-timed-out", isDirectory: true)),
    ]
  }

  /// Moves each old folder to its new name. Returns one line per folder
  /// that existed, for the log.
  @discardableResult
  public static func migrate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             temporary: URL = FileManager.default.temporaryDirectory) -> [String] {
    moves(home: home, temporary: temporary).compactMap { move in
      let fm = FileManager.default
      guard fm.fileExists(atPath: move.from.path) else { return nil }
      var left: [String] = []
      merge(move.from, into: move.to, left: &left)
      let name = "\(move.from.lastPathComponent) → \(move.to.path)"
      return left.isEmpty ? "moved \(name)" : "moved \(name); left in place (name taken): \(left.joined(separator: ", "))"
    }
  }

  /// Moves `source` to `destination`, merging folders file by file.
  private static func merge(_ source: URL, into destination: URL, left: inout [String]) {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
      do {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
      } catch {
        left.append(source.lastPathComponent)
      }
      return
    }
    var sourceIsDirectory: ObjCBool = false
    guard isDirectory.boolValue, fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
          sourceIsDirectory.boolValue,
          let children = try? fm.contentsOfDirectory(atPath: source.path) else {
      left.append(source.lastPathComponent)
      return
    }
    for child in children {
      merge(source.appendingPathComponent(child), into: destination.appendingPathComponent(child), left: &left)
    }
    // Only an empty folder goes; anything left keeps its place.
    if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
      try? fm.removeItem(at: source)
    }
  }
}
