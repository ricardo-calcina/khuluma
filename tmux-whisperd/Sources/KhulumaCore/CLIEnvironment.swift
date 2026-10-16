import Foundation

/// The environment Lowkey gives the `tmux-whisper` CLI.
public enum CLIEnvironment {
  /// Lowkey's own environment depends on how it was launched: from Finder,
  /// Spotlight or at login it has no locale, but `open` from a terminal can
  /// pass the shell's (e.g. LANG=C.UTF-8). The CLI's mode detection (grep -i,
  /// sed, glob order) behaves differently per locale and the native pipeline
  /// reproduces the C locale, so locale variables are dropped: the CLI always
  /// runs in C, as for a login launch. A locale set in ~/.zshenv (which the
  /// CLI sources) is still reported by app-config and still means CLI path.
  public static func forCLI(base: [String: String], home: String) -> [String: String] {
    var environment = base.filter { key, _ in key != "LANG" && !key.hasPrefix("LC_") }
    // Apps launched from Finder get a minimal PATH; the CLI needs Homebrew tools.
    environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    return environment
  }
}
