import Foundation
import Darwin

/// Explicit developer isolation for staged-app acceptance. Ordinary installs
/// keep the existing Khuluma paths. All three overrides are required together
/// so a test instance cannot accidentally mix private and daily state.
public enum AppRuntimePaths {
  private static let isolationKeys = ["KHULUMA_SUPPORT_DIR", "KHULUMA_LOG_DIR", "KHULUMA_DEFAULTS_SUITE"]

  public static func isIsolated(environment: [String: String]) -> Bool {
    isolationKeys.contains { environment[$0]?.isEmpty == false }
  }

  public static func isolationIssue(environment: [String: String], home: URL, expectedOwner: UInt32 = getuid()) -> String? {
    guard isIsolated(environment: environment) else { return nil }
    guard isolationKeys.allSatisfy({ environment[$0]?.isEmpty == false }) else {
      return "Isolated launch requires KHULUMA_SUPPORT_DIR, KHULUMA_LOG_DIR and KHULUMA_DEFAULTS_SUITE together"
    }
    for key in ["KHULUMA_SUPPORT_DIR", "KHULUMA_LOG_DIR"] {
      let path = environment[key]!
      guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
        return "\(key) must name an absolute private fixture directory without traversal components"
      }
      if let issue = ancestryIssue(URL(fileURLWithPath: path), owner: expectedOwner) { return issue }
    }
    // Foundation standardization can rewrite a physical /private/var path to
    // the /var symlink. Keep explicit paths intact after checking ancestry.
    let support = URL(fileURLWithPath: environment["KHULUMA_SUPPORT_DIR"]!)
    let logs = URL(fileURLWithPath: environment["KHULUMA_LOG_DIR"]!)
    let parent = support.deletingLastPathComponent()
    guard support != logs, parent == logs.deletingLastPathComponent() else {
      return "Isolated support and log directories must be distinct children of one private fixture root"
    }
    let home = physicalDirectory(home)
    let broadHomeDirectories = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]
      .map { home.appendingPathComponent($0) }
    guard !broadHomeDirectories.contains(parent) else {
      return "Use a dedicated private fixture root rather than a broad home directory: \(parent.path)"
    }
    let protected = ["Library", ".config", ".local", ".ssh", ".codex"].map { home.appendingPathComponent($0) }
      + ["/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/opt", "/etc",
         "/private/etc", "/private/var/db", "/private/var/root"].map { URL(fileURLWithPath: $0) }
      + ["khuluma-timed-out", "lowkey-timed-out"].map { physicalDirectory(FileManager.default.temporaryDirectory).appendingPathComponent($0) }
    for directory in [parent, support, logs] {
      guard !contains(directory, home), !protected.contains(where: { contains($0, directory) || contains(directory, $0) }) else {
        return "Isolated state cannot use home, system or daily application data trees: \(directory.path)"
      }
    }
    // Data overrides must not lead an isolated run back into real data: the
    // shared model cache, the CLI-era data folder or the daily app folder.
    let realData = realDataRoots(home: home)
    for key in ["KHULUMA_DEFAULT_MODEL_DIR", "XDG_DATA_HOME", "SOUNDS_DIR"] {
      guard let value = environment[key], !value.isEmpty else { continue }
      // The folder and the subfolders the app appends to it.
      let subpaths: [String] = key == "XDG_DATA_HOME" ? ["", "sounds/khuluma", "khuluma/models"]
        : key == "SOUNDS_DIR" ? ["", "khuluma"] : ["", "parakeet-tdt-0.6b-v3"]
      let candidates = subpaths.map { URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent($0, isDirectory: true) }
      if candidates.contains(where: { url in
        realData.contains { contains($0, physicalDirectory(url)) || contains($0, url.standardizedFileURL) }
      }) {
        return "\(key) must not point into real Khuluma or FluidAudio data in an isolated run: \(value)"
      }
    }
    guard environment["KHULUMA_DEFAULTS_SUITE"]!.hasPrefix("com.ricardo-nth.khuluma.") else {
      return "Isolated launch requires a separate Khuluma defaults suite"
    }
    guard privateDirectory(parent, owner: expectedOwner) else {
      return "Fixture root must already exist as an owned private directory (0700): \(parent.path)"
    }
    for directory in [support, logs] {
      if metadata(directory) != nil && !privateDirectory(directory, owner: expectedOwner) {
        return "Isolated state must be an owned private directory (0700): \(directory.path)"
      }
    }
    return nil
  }

  /// Case-insensitive: APFS volumes usually are, so `~/library/...` is the
  /// same folder as `~/Library/...`. Refusing a few extra paths on a
  /// case-sensitive volume is the safe direction.
  private static func contains(_ parent: URL, _ child: URL) -> Bool {
    let p = parent.path.lowercased(), c = child.path.lowercased()
    return p == c || c.hasPrefix(p == "/" ? "/" : p + "/")
  }

  /// The path with symlinks resolved. A path that doesn't exist yet
  /// resolves through its nearest existing ancestor, so
  /// `<symlink to real data>/<new child>` still lands inside real data.
  static func physicalDirectory(_ directory: URL) -> URL {
    var existing = directory.standardizedFileURL
    var rest: [String] = []
    while true {
      if let path = realpath(existing.path, nil) {
        defer { free(path) }
        var url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        for component in rest.reversed() { url.appendPathComponent(component, isDirectory: true) }
        return url
      }
      guard existing.path != "/" else { return directory }
      rest.append(existing.lastPathComponent)
      existing.deleteLastPathComponent()
    }
  }

  private static func metadata(_ url: URL) -> stat? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? info : nil
  }

  private static func privateDirectory(_ url: URL, owner: UInt32) -> Bool {
    guard let info = metadata(url) else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == owner
      && (info.st_mode & 0o077) == 0 && (info.st_mode & 0o700) == 0o700
  }

  private static func ancestryIssue(_ url: URL, owner: UInt32) -> String? {
    var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      ancestor.appendPathComponent(component)
      guard let info = metadata(ancestor) else { break }
      guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == owner || info.st_uid == 0 else {
        return "Refusing symlink, non-directory or unowned isolation path: \(ancestor.path)"
      }
    }
    return nil
  }

  public static func supportDirectory(environment: [String: String], home: URL) -> URL {
    if let path = environment["KHULUMA_SUPPORT_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
    return home.appendingPathComponent("Library/Application Support/Khuluma", isDirectory: true)
  }

  public static func logDirectory(environment: [String: String], home: URL) -> URL {
    if let path = environment["KHULUMA_LOG_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
    return home.appendingPathComponent("Library/Logs/Khuluma", isDirectory: true)
  }

  /// Where the default Parakeet v3 model lives. Ordinary runs: FluidAudio's
  /// shared cache (`sharedCache`, which other apps use too). Isolated runs
  /// never touch it: `<models>/<the cache's folder name>`, where `<models>`
  /// is KHULUMA_DEFAULT_MODEL_DIR (a parent models folder) when set, else
  /// `<support>/models`. FluidAudio downloads into `<parent>/<fixed repo
  /// folder name>`, so the target always matches what it writes. The app (reading,
  /// downloading, repairing, locking) and the `khuluma` helper both use this.
  public static func defaultModelDirectory(environment: [String: String], home: URL, sharedCache: URL) -> URL {
    guard isIsolated(environment: environment) else { return sharedCache }
    let parent = environment["KHULUMA_DEFAULT_MODEL_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
      ?? supportDirectory(environment: environment, home: home).appendingPathComponent("models", isDirectory: true)
    return parent.appendingPathComponent(sharedCache.lastPathComponent, isDirectory: true)
  }

  /// Folders an isolated run must never read or write: FluidAudio's shared
  /// model cache, the CLI-era data folder and the daily app folder.
  public static func realDataRoots(home: URL) -> [URL] {
    [home.appendingPathComponent("Library/Application Support/FluidAudio"),
     home.appendingPathComponent(".local/share"),
     home.appendingPathComponent("Library/Application Support/Khuluma")].map(physicalDirectory)
  }

  /// `path` is in or under one of `realDataRoots` (resolved or as written).
  public static func isRealData(_ path: String, home: URL) -> Bool {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let resolved = physicalDirectory(url), literal = url.standardizedFileURL
    return realDataRoots(home: home).contains { contains($0, resolved) || contains($0, literal) }
  }

  public static var isolated: Bool { isIsolated(environment: ProcessInfo.processInfo.environment) }
  public static var support: URL {
    supportDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  public static var logs: URL {
    logDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  public static var temporary: URL {
    temporaryDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  public static func temporaryDirectory(environment: [String: String], home: URL) -> URL {
    isIsolated(environment: environment)
      ? supportDirectory(environment: environment, home: home).appendingPathComponent("temporary", isDirectory: true)
      : FileManager.default.temporaryDirectory
  }
  public static var defaults: UserDefaults {
    if let suite = ProcessInfo.processInfo.environment["KHULUMA_DEFAULTS_SUITE"], !suite.isEmpty {
      guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Invalid isolated defaults suite") }
      return defaults
    }
    return .standard
  }

  public static func prepareIsolation(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    if let issue = isolationIssue(environment: environment, home: home) {
      throw NSError(domain: "Khuluma", code: 5, userInfo: [NSLocalizedDescriptionKey: issue])
    }
    if isIsolated(environment: environment) {
      let support = supportDirectory(environment: environment, home: home)
      let logs = logDirectory(environment: environment, home: home)
      for directory in [support, logs, support.appendingPathComponent("temporary", isDirectory: true)] {
        if metadata(directory) == nil {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard privateDirectory(directory, owner: getuid()) else {
          throw NSError(domain: "Khuluma", code: 5, userInfo: [NSLocalizedDescriptionKey: "Isolation directory changed or is not private: \(directory.path)"])
        }
      }
    }
  }
}
