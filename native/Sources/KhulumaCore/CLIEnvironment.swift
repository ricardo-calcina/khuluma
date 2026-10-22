import Foundation

/// The environment Khuluma gives the `khuluma` CLI.
public enum CLIEnvironment {
  /// Checked by the bridge before creating files or launching any candidate.
  /// A stale canonical CLI may still translate these obsolete inputs.
  public static func obsoleteOverrideNames(base: [String: String]) -> [String] {
    base.keys.filter {
      $0.hasPrefix("DICTATE_") || $0 == "LOWKEY_KEYCHAIN" || $0 == "LOWKEY_SIGNING_IDENTITY"
    }.sorted()
  }

  /// A GUI fallback until app-config reports the authoritative effective root.
  public static func configDirectory(base: [String: String], home: String) -> String {
    func nonempty(_ key: String) -> String? { base[key].flatMap { $0.isEmpty ? nil : $0 } }
    let directory = nonempty("KHULUMA_CONFIG_DIR")
      ?? ((nonempty("XDG_CONFIG_HOME") ?? "\(home)/.config") + "/khuluma")
    return directory.hasPrefix("~/") ? home + directory.dropFirst() : directory
  }

  /// Khuluma's own environment depends on how it was launched: from Finder,
  /// Spotlight or at login it has no locale, but `open` from a terminal can
  /// pass the shell's (e.g. LANG=C.UTF-8). The CLI's text cleanup behaves
  /// differently per locale and the native pipeline reproduces the C locale,
  /// so locale variables are dropped: the CLI always runs in C, as for a
  /// login launch. A locale set in ~/.zshenv (which the CLI sources) is still
  /// reported by app-config and still means CLI path.
  public static func forCLI(base: [String: String], home: String) -> [String: String] {
    var environment = base.filter { key, _ in key != "LANG" && !key.hasPrefix("LC_") }
    // Apps launched from Finder get a minimal PATH; the CLI needs Homebrew tools.
    environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    return environment
  }
}
