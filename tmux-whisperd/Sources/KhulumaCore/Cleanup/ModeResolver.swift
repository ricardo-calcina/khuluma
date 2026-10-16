import Foundation

/// Port of the CLI's inline mode resolution (bin/tmux-whisper-lib/mode.sh:
/// `resolve_inline_mode` → `get_current_mode` / `detect_mode` /
/// `default_inline_mode`), reading the same files under the config dir.
///
/// The CLI that Lowkey starts runs in the C locale, so names compare as bytes,
/// case folding is ASCII-only and mode folders are visited in byte order.
public struct ModeResolver: Sendable {
  public let configDir: String

  public init(configDir: String) {
    self.configDir = configDir
  }

  /// Mode for an inline take. `app` is the target app's name (Lowkey passes
  /// the frontmost app). With no app the CLI asks System Events for the
  /// frontmost process; here the default inline mode is used instead.
  public func resolveInlineMode(app: String?, forceMode: String? = nil) -> String {
    let mode = currentMode(app: app ?? "", forceMode: forceMode ?? "")
    if !modeExists(mode) || !modeAllowsFlow(mode, flow: "inline") {
      return defaultInlineMode()
    }
    return mode
  }

  // MARK: mode.sh

  private var modesDir: String { configDir + "/modes" }

  /// `canonical_mode_name`: empty means "code".
  static func canonical(_ mode: String) -> String {
    mode.isEmpty ? "code" : mode
  }

  func modeExists(_ mode: String) -> Bool {
    PerlText.isDirectory(modesDir + "/" + ModeResolver.canonical(mode))
  }

  /// `mode_allows_flow`: no flows file, or one with no entries, allows all.
  func modeAllowsFlow(_ mode: String, flow: String) -> Bool {
    if flow.isEmpty { return true }
    let path = modesDir + "/" + ModeResolver.canonical(mode) + "/flows"
    guard PerlText.isFile(path) else { return true }
    guard let contents = PerlText.readFile(path) else { return true }
    var sawEntries = false
    for rawLine in PerlText.fileLines(contents) {
      var line = rawLine
      if let hash = line.unicodeScalars.firstIndex(of: "#") {
        line = String(line.unicodeScalars[..<hash])
      }
      line = PerlText.asciiTrimmed(PerlText.asciiLowercased(line))
      if line.isEmpty { continue }
      sawEntries = true
      switch line {
      case "all", "both": return true
      case "tmux", "inline": if line == flow { return true }
      default: break
      }
    }
    return !sawEntries
  }

  /// Names matched by the `"$DICTATE_CONFIG_DIR/modes"/*/` glob: visible
  /// directories (symlinks followed), in C-locale (byte) order.
  func modeDirectoryNames() -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: modesDir) else { return [] }
    return names
      .filter { !$0.hasPrefix(".") && PerlText.isDirectory(modesDir + "/" + $0) }
      .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
  }

  func listModes(flow: String) -> [String] {
    // `sort -u` in the C locale: unique by bytes (a Set<String> would merge
    // canonically equivalent names).
    var seen = Set<[UInt8]>()
    return modeDirectoryNames()
      .map(ModeResolver.canonical)
      .filter { modeExists($0) && modeAllowsFlow($0, flow: flow) }
      .filter { seen.insert(Array($0.utf8)).inserted }
  }

  func firstModeForFlow(_ flow: String) -> String {
    if modeExists("code") && modeAllowsFlow("code", flow: flow) { return "code" }
    return listModes(flow: flow).first ?? "code"
  }

  func defaultInlineMode() -> String {
    if modeExists("base") && modeAllowsFlow("base", flow: "inline") { return "base" }
    return firstModeForFlow("inline")
  }

  func normalizeModeName(_ mode: String) -> String {
    let canonical = ModeResolver.canonical(mode)
    return modeExists(canonical) ? canonical : firstModeForFlow("")
  }

  func detectMode(app: String) -> String {
    guard !app.isEmpty else { return defaultInlineMode() }
    let matcher = ModeResolver.appLineMatcher(app)
    for name in modeDirectoryNames() {
      let appsFile = modesDir + "/" + name + "/apps"
      guard PerlText.isFile(appsFile) else { continue }
      guard modeAllowsFlow(name, flow: "inline") else { continue }
      guard let matcher, let contents = FileManager.default.contents(atPath: appsFile) else { continue }
      if ModeResolver.anyLineMatches(contents, matcher) {
        return normalizeModeName(name)
      }
    }
    return defaultInlineMode()
  }

  func currentMode(app: String, forceMode: String) -> String {
    if !forceMode.isEmpty { return normalizeModeName(forceMode) }
    let modeFile = configDir + "/current-mode"
    guard PerlText.isFile(modeFile) else { return detectMode(app: app) }
    let contents = PerlText.readFile(modeFile) ?? ""
    let firstLine = PerlText.fileLines(contents).first ?? ""
    let saved = PerlText.asciiTrimmed(String(String.UnicodeScalarView(firstLine.unicodeScalars.filter { $0 != "\r" })))
    if saved.isEmpty || saved == "auto" { return detectMode(app: app) }
    if modeExists(saved) && modeAllowsFlow(saved, flow: "inline") { return normalizeModeName(saved) }
    return detectMode(app: app)
  }

  // MARK: grep -iq "^${app}$" apps_file

  /// The app name is used as a basic regular expression (BRE) by BSD grep in
  /// the C locale: `.` is any byte, `*` repeats (literal when first), `\x`
  /// is a literal x, everything else is literal, ASCII case-insensitive.
  /// Bracket expressions are not supported: names containing `[` never
  /// match here (grep would treat them as a character class).
  static func appLineMatcher(_ app: String) -> ICURegex? {
    let scalars = Array(PerlText.byteView(app.utf8).unicodeScalars)
    let pattern: String = {
      var pattern = "^"
      var atStart = true
      var lastWasStar = false
      var index = 0
      while index < scalars.count {
        let scalar = scalars[index]
        index += 1
        switch scalar {
        case "\\":
          guard index < scalars.count else { return "" }
          pattern += literal(scalars[index])
          index += 1
          lastWasStar = false
        case ".":
          pattern += "."
          lastWasStar = false
        case "*":
          if atStart {
            pattern += "\\*"
          } else if !lastWasStar {
            pattern += "*"
            lastWasStar = true
          }
        case "[":
          return ""
        default:
          pattern += literal(scalar)
          lastWasStar = false
        }
        atStart = false
      }
      return pattern + "$"
    }()
    return pattern.isEmpty ? nil : try? ICURegex(validating: pattern)
  }

  private static func literal(_ scalar: Unicode.Scalar) -> String {
    switch scalar.value {
    case 65...90: return "[\(scalar)\(Unicode.Scalar(scalar.value + 32)!)]"
    case 97...122: return "[\(Unicode.Scalar(scalar.value - 32)!)\(scalar)]"
    default: return NSRegularExpression.escapedPattern(for: String(scalar))
    }
  }

  private static func anyLineMatches(_ data: Data, _ matcher: ICURegex) -> Bool {
    // Byte view of each line, so `.` matches a single byte like grep.
    let lines = PerlText.fileLines(PerlText.byteView(data))
    return lines.contains { matcher.isMatch($0) }
  }
}
