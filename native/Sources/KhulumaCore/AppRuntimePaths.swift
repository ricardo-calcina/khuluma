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
    guard environment["KHULUMA_DEFAULTS_SUITE"]!.hasPrefix(LegacyPreferences.canonicalDomain + ".") else {
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

  private static func contains(_ parent: URL, _ child: URL) -> Bool {
    parent.path == child.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
  }

  private static func physicalDirectory(_ directory: URL) -> URL {
    guard let path = realpath(directory.path, nil) else { return directory }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
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

  public static var isolated: Bool { isIsolated(environment: ProcessInfo.processInfo.environment) }
  public static var support: URL {
    supportDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  public static var logs: URL {
    logDirectory(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
  }
  public static var temporary: URL {
    isolated ? support.appendingPathComponent("temporary", isDirectory: true) : FileManager.default.temporaryDirectory
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
