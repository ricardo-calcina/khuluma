import Foundation
import Security

/// Where the app keeps the ElevenLabs key it was given in Settings.
public protocol ScribeKeychain: Sendable {
  func read() -> String?
  func save(_ key: String) throws
  func remove() throws
}

/// The macOS Keychain (a generic password). Isolated runs use their own
/// item so a worktree check can't read or delete the daily app's key.
public struct SystemScribeKeychain: ScribeKeychain {
  public static let service = "app.khuluma.elevenlabs"
  public static let account = "api-key"
  public let service: String

  public init(isolated: Bool = AppRuntimePaths.isolated) {
    service = isolated ? Self.service + ".isolated" : Self.service
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: Self.account]
  }

  public func read() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func save(_ key: String) throws {
    let data = Data(key.utf8)
    let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw KeychainError(status: update) }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }

  public struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    public var errorDescription: String? { "The Keychain refused the change (code \(status))." }
  }
}

/// Finds the ElevenLabs key: the Keychain first, then the CLI's read-only
/// lookup (a port of `providers.py credential()`): the environment, then
/// exported literals in the zsh rc files. The key is returned to the caller
/// for one request and never stored here, logged or passed as an argument.
public struct ScribeCredential: Sendable {
  public enum Source: String, Sendable {
    case keychain
    case environment
    case shellSettings
  }

  public static let keyNames = ["ELEVENLABS_API_KEY", "ELEVEN_LABS_API_KEY"]

  public let keychain: ScribeKeychain
  public let environment: [String: String]
  public let home: URL

  public init(keychain: ScribeKeychain = SystemScribeKeychain(),
              environment: [String: String] = ProcessInfo.processInfo.environment,
              home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.keychain = keychain
    self.environment = environment
    self.home = home
  }

  /// The key and where it came from. Hold the result only for the request.
  public func lookup() -> (key: String, source: Source)? {
    if let stored = keychain.read() {
      let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
      if !key.isEmpty, !key.unicodeScalars.contains(where: { $0.value < 32 }) { return (key, .keychain) }
    }
    if let inherited = shellLookup() { return inherited }
    return nil
  }

  /// Presence only.
  public var source: Source? { lookup()?.source }
  public var isAvailable: Bool { source != nil }

  /// Settings page: save a key typed there. Trims; refuses empty or control characters.
  public func save(_ typed: String) throws {
    let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
      throw Invalid()
    }
    try keychain.save(key)
  }

  public func removeStored() throws { try keychain.remove() }

  public struct Invalid: Error, LocalizedError {
    public var errorDescription: String? { "That is not a valid API key." }
  }

  // MARK: providers.py credential()

  func shellLookup() -> (key: String, source: Source)? {
    for name in Self.keyNames {
      let inherited = PyText.strip(environment[name] ?? "")
      if !inherited.isEmpty {
        // providers.py gives up entirely on a control character.
        return inherited.unicodeScalars.contains(where: { $0.value < 32 }) ? nil : (inherited, .environment)
      }
    }
    // Isolated runs read only the (.isolated) Keychain item and the
    // environment, never the user's shell files.
    guard !AppRuntimePaths.isIsolated(environment: environment) else { return nil }
    var candidates: [String] = []
    if let zdotdir = environment["ZDOTDIR"], !zdotdir.isEmpty {
      candidates.append(PyText.join(PyText.expandUser(zdotdir, home: home.path), ".zshrc"))
    }
    candidates.append(PyText.join(home.path, ".config/zsh/.zshrc"))
    candidates.append(PyText.join(home.path, ".zshrc"))
    var seen = Set<String>()
    for path in candidates where seen.insert(PyText.normalize(path)).inserted {
      if let key = Self.keyFromRC(path: path, home: home.path) { return (key, .shellSettings) }
    }
    return nil
  }

  static func keyFromRC(path: String, home: String) -> String? {
    var found: [String: String] = [:]
    var privateDeclared = false
    let parent = PyText.parent(path)
    for line in PyText.readLines(path) {
      for name in keyNames {
        if let value = exportedLiteral(line, name: name), !value.isEmpty { found[name] = value }
      }
      if let declaration = privateSiblingAssignment(line, rcParent: parent, home: home) {
        privateDeclared = declaration
      }
      guard let words = Shlex.split(line) else { continue }
      if privateDeclared, words.count == 2, words[0] == "source" || words[0] == ".",
         words[1] == "$zsh_private_env" || words[1] == "${zsh_private_env}" {
        for privateLine in PyText.readLines(PyText.join(parent, ".zshrc.private")) {
          for name in keyNames {
            if let value = exportedLiteral(privateLine, name: name), !value.isEmpty { found[name] = value }
          }
        }
      }
    }
    for name in keyNames { if let value = found[name], !value.isEmpty { return value } }
    return nil
  }

  /// `\s*export\s+NAME\s*=\s*(.*?)\s*` with no `$`, backtick or `;`, one
  /// shell word of `[A-Za-z0-9_-]+`.
  static func exportedLiteral(_ line: String, name: String) -> String? {
    var rest = Substring(PyText.lstrip(line))
    guard rest.hasPrefix("export") else { return nil }
    rest = rest.dropFirst(6)
    guard let first = rest.unicodeScalars.first, PyText.isSpace(first) else { return nil }
    rest = Substring(PyText.lstrip(String(rest)))
    guard rest.hasPrefix(name) else { return nil }
    rest = rest.dropFirst(name.count)
    rest = Substring(PyText.lstrip(String(rest)))
    guard rest.hasPrefix("=") else { return nil }
    let value = PyText.strip(String(rest.dropFirst()))
    if value.contains("$") || value.contains("`") || value.contains(";") { return nil }
    guard let words = Shlex.split(value), words.count == 1 else { return nil }
    let word = words[0]
    guard !word.isEmpty, word.unicodeScalars.allSatisfy({ s in
      (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
        || s == "_" || s == "-"
    }) else { return nil }
    return word
  }

  /// nil: not a declaration; false: declared something else (or unparsable);
  /// true: the conventional `.zshrc.private` sibling.
  static func privateSiblingAssignment(_ line: String, rcParent: String, home: String) -> Bool? {
    var rest = Substring(PyText.lstrip(line))
    if rest.hasPrefix("export"), rest.dropFirst(6).unicodeScalars.first.map(PyText.isSpace) == true {
      rest = Substring(PyText.lstrip(String(rest.dropFirst(6))))
    }
    guard rest.hasPrefix("zsh_private_env") else { return nil }
    rest = Substring(PyText.lstrip(String(rest.dropFirst("zsh_private_env".count))))
    guard rest.hasPrefix("=") else { return nil }
    let value = PyText.strip(String(rest.dropFirst()))
    guard let values = Shlex.split(value) else { return false }
    var permitted: Set<String> = ["${ZDOTDIR:-$HOME}/.zshrc.private", "$ZDOTDIR/.zshrc.private", "${ZDOTDIR}/.zshrc.private"]
    if PyText.normalize(rcParent) == PyText.normalize(home) {
      permitted.formUnion(["$HOME/.zshrc.private", "${HOME}/.zshrc.private"])
    }
    return values.count == 1 && permitted.contains(values[0])
  }
}

/// The few Python string and path behaviours the port depends on.
enum PyText {
  /// `str.isspace()` for one character.
  static func isSpace(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
  }

  static func lstrip(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.drop(while: isSpace)))
  }

  static func strip(_ text: String) -> String {
    var scalars = Array(lstrip(text).unicodeScalars)
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }

  /// `str.splitlines()`.
  static func splitLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var previousCR = false
    for s in text.unicodeScalars {
      if previousCR {
        previousCR = false
        if s == "\n" { continue }
      }
      switch s.value {
      case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
        lines.append(String(current)); current = String.UnicodeScalarView()
      case 0x0D:
        lines.append(String(current)); current = String.UnicodeScalarView(); previousCR = true
      default: current.append(s)
      }
    }
    if !current.isEmpty { lines.append(String(current)) }
    return lines
  }

  /// `path.read_text(encoding="utf-8").splitlines()`, or [] on any failure.
  static func readLines(_ path: String) -> [String] {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
    return splitLines(text)
  }

  static func expandUser(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return join(home, String(path.dropFirst(2))) }
    return path
  }

  static func join(_ base: String, _ name: String) -> String {
    base.hasSuffix("/") ? base + name : base + "/" + name
  }

  /// `pathlib` normalisation: no empty or "." components, no trailing slash.
  static func normalize(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
  }

  static func parent(_ path: String) -> String {
    let normal = normalize(path)
    guard let slash = normal.lastIndex(of: "/") else { return "." }
    return slash == normal.startIndex ? "/" : String(normal[..<slash])
  }
}

/// `shlex.split(text, comments=True, posix=True)`; nil where Python raises ValueError.
enum Shlex {
  static func split(_ text: String) -> [String]? {
    let chars = Array(text.unicodeScalars)
    var tokens: [String] = []
    var token = String.UnicodeScalarView()
    var inWord = false
    func flush() {
      if inWord { tokens.append(String(token)) }
      token = String.UnicodeScalarView()
      inWord = false
    }
    var i = 0
    while i < chars.count {
      let c = chars[i]
      switch c {
      case " ", "\t", "\r", "\n":
        flush(); i += 1
      case "#":
        flush(); return tokens
      case "\\":
        guard i + 1 < chars.count else { return nil }
        token.append(chars[i + 1]); inWord = true; i += 2
      case "'":
        guard let end = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
        token.append(contentsOf: chars[(i + 1)..<end]); inWord = true; i = end + 1
      case "\"":
        var j = i + 1
        var closed = false
        while j < chars.count {
          let d = chars[j]
          if d == "\"" { closed = true; break }
          if d == "\\" {
            guard j + 1 < chars.count else { return nil }
            let e = chars[j + 1]
            if e != "\"" && e != "\\" { token.append("\\") }
            token.append(e); j += 2
          } else { token.append(d); j += 1 }
        }
        guard closed else { return nil }
        inWord = true; i = j + 1
      default:
        token.append(c); inWord = true; i += 1
      }
    }
    flush()
    return tokens
  }
}
