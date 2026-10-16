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
      guard exists(move.from) else { return nil }
      var left: [String] = []
      merge(move.from, into: move.to, left: &left)
      let name = "\(move.from.lastPathComponent) → \(move.to.path)"
      return left.isEmpty ? "moved \(name)" : "moved \(name); left in place: \(left.joined(separator: ", "))"
    }
  }

  private static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  /// Not followed: a link could point anywhere, so it's left alone.
  private static func isSymlink(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
  }

  /// Moves `source` to `destination`. When both are folders, their contents
  /// merge: files sharing a name before the extension (a timed-out take's
  /// .wav and .json) move together or not at all.
  private static func merge(_ source: URL, into destination: URL, left: inout [String]) {
    let fm = FileManager.default
    if isSymlink(source) || isSymlink(destination) {
      left.append("\(source.lastPathComponent) (symlink)")
      return
    }
    guard exists(destination) else {
      do {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
      } catch {
        left.append("\(source.lastPathComponent) (\(error.localizedDescription))")
      }
      return
    }
    guard isDirectory(source), isDirectory(destination),
          let children = try? fm.contentsOfDirectory(atPath: source.path) else {
      left.append("\(source.lastPathComponent) (name taken)")
      return
    }
    let groups = Dictionary(grouping: children) { ($0 as NSString).deletingPathExtension }
    for stem in groups.keys.sorted() {
      let names = groups[stem]!.sorted()
      if names.count == 1, isDirectory(source.appendingPathComponent(names[0])) {
        merge(source.appendingPathComponent(names[0]), into: destination.appendingPathComponent(names[0]), left: &left)
        continue
      }
      moveTogether(names, from: source, to: destination, left: &left)
    }
    // Only an empty folder goes; anything left keeps its place.
    if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
      try? fm.removeItem(at: source)
    }
  }

  /// Moves files that belong together, or none of them: if one can't move,
  /// those already moved go back.
  private static func moveTogether(_ names: [String], from source: URL, to destination: URL, left: inout [String]) {
    let fm = FileManager.default
    if let taken = names.first(where: { exists(destination.appendingPathComponent($0)) }) {
      left.append(contentsOf: names.map { "\($0) (\(taken == $0 ? "name taken" : "kept with \(taken)"))" })
      return
    }
    if names.contains(where: { isSymlink(source.appendingPathComponent($0)) || isDirectory(source.appendingPathComponent($0)) }) {
      left.append(contentsOf: names.map { "\($0) (not a plain file group)" })
      return
    }
    var moved: [String] = []
    for name in names {
      do {
        try fm.moveItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        moved.append(name)
      } catch {
        for back in moved {
          try? fm.moveItem(at: destination.appendingPathComponent(back), to: source.appendingPathComponent(back))
        }
        left.append(contentsOf: names.map { "\($0) (\(error.localizedDescription))" })
        return
      }
    }
  }
}
