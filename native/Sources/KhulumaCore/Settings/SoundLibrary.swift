import Foundation

/// What an event's pop-up shows: the bundled default, silent, a file, or a
/// configured file that has gone missing.
public enum SoundChoice: Equatable, Sendable {
  case standard
  case none
  case file(String)
  case missing(String)

  /// `sound` is the configured `audio.sounds.<event>` (path unresolved);
  /// `expand` applies the resolver's `~`/`$SOUNDS_DIR` expansion.
  public static func current(sound: AppSettings.Sound, fileExists: (String) -> Bool,
                             expand: (String) -> String) -> SoundChoice {
    guard sound.enabled else { return .none }
    guard !sound.path.isEmpty else { return .standard }
    let path = expand(sound.path)
    return fileExists(path) ? .file(path) : .missing(path)
  }
}

/// `<support>/sounds`: where a user's own sound files live and where
/// "Choose File…" copies its pick. Pure file operations; the UI decides
/// which file maps to which event.
public struct SoundLibrary: Sendable {
  public static let extensions: Set<String> = ["wav", "aiff", "aif", "m4a", "mp3", "caf"]

  public let directory: URL

  public static var standard: SoundLibrary {
    SoundLibrary(directory: AppRuntimePaths.support.appendingPathComponent("sounds", isDirectory: true))
  }

  public init(directory: URL) {
    self.directory = directory
  }

  /// Regular, visible, playable files, sorted case-insensitively by name;
  /// [] when the folder is missing.
  public func files() -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    return urls.filter { url in
      !url.lastPathComponent.hasPrefix(".")
        && Self.extensions.contains(url.pathExtension.lowercased())
        && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
  }

  /// Copies `source` into the folder under its own file name (0700 folder,
  /// 0600 file). An existing file with identical bytes is returned as is;
  /// otherwise "name 2.ext", "name 3.ext", … Never overwrites.
  @discardableResult
  public func importFile(_ source: URL) throws -> URL {
    let ext = source.pathExtension.lowercased()
    guard Self.extensions.contains(ext) else {
      throw CocoaError(.fileWriteUnsupportedScheme, userInfo: [
        NSLocalizedDescriptionKey: "\(source.lastPathComponent) is not an audio file Khuluma can play"])
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try Data(contentsOf: source)
    let stem = source.deletingPathExtension().lastPathComponent
    var n = 1
    while true {
      let name = n == 1 ? "\(stem).\(ext)" : "\(stem) \(n).\(ext)"
      let candidate = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: candidate.path) else {
        try data.write(to: candidate, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        return candidate
      }
      if (try? Data(contentsOf: candidate)) == data { return candidate }
      n += 1
    }
  }
}
