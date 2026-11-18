import Foundation

/// Reads and writes `settings.json` in the app folder. A file that doesn't
/// parse falls back to the last valid copy (`.settings.json.last-good`), then
/// to the defaults, reported as `AppConfig.ConfigStatus` so the safe-delivery
/// rule (no autosend on fallback defaults) still applies. Writes hold the
/// app's data lock and replace the file atomically; keys this version doesn't
/// know are kept.
public struct SettingsStore: Sendable {
  public let folder: URL
  public let lockTimeout: TimeInterval
  /// Never writes (the bundled `khuluma` helper): `load` skips refreshing
  /// the last-good copy.
  public var readOnly = false

  public init(folder: URL = AppRuntimePaths.support, lockTimeout: TimeInterval = 5) {
    self.folder = folder
    self.lockTimeout = lockTimeout
  }

  /// Keys older builds wrote that this version no longer models; dropped
  /// from the file on the next write.
  static let retiredKeys: [(section: String?, key: String)] = [(nil, "import_warning"), ("transcription", "socket_path")]

  public var url: URL { folder.appendingPathComponent(AppSettings.fileName) }
  public var lastGoodURL: URL { folder.appendingPathComponent("." + AppSettings.fileName + ".last-good") }
  var lockURL: URL { folder.appendingPathComponent(".data.lock") }

  public struct Loaded: Equatable, Sendable {
    public let settings: AppSettings
    public let status: AppConfig.ConfigStatus
  }

  public struct InvalidSetting: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }

  // MARK: Load

  /// The settings, never failing: an invalid file falls back as described
  /// above. A missing file is the defaults with no error. After a good load
  /// the last valid copy is refreshed (best effort).
  public func load() -> Loaded {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return Loaded(settings: AppSettings(), status: .init(error: nil, source: "file"))
    } catch {
      return fallback(error.localizedDescription)
    }
    do {
      let settings = try Self.decode(data)
      if !readOnly { refreshLastGood(data) }
      return Loaded(settings: settings, status: .init(error: nil, source: "file"))
    } catch {
      return fallback(Self.describe(error))
    }
  }

  /// The settings as AppConfig, the app's in-memory model.
  public func appConfig(environment: SettingsEnvironment) -> AppConfig {
    let loaded = load()
    return AppConfig(settings: loaded.settings, status: loaded.status, environment: environment)
  }

  private func fallback(_ error: String) -> Loaded {
    if let data = try? Data(contentsOf: lastGoodURL), let settings = try? Self.decode(data) {
      return Loaded(settings: settings, status: .init(error: error, source: "last_good"))
    }
    return Loaded(settings: AppSettings(), status: .init(error: error, source: "defaults"))
  }

  private func refreshLastGood(_ data: Data) {
    if (try? Data(contentsOf: lastGoodURL)) == data { return }
    try? DataFiles.withLock(lockURL, timeout: 1) {
      // Only if settings.json still holds what was read, so a slow reader
      // never replaces a newer copy with older settings.
      guard (try? Data(contentsOf: url)) == data else { return }
      try DataFiles.replace(lastGoodURL, with: data)
    }
  }

  static func decode(_ data: Data) throws -> AppSettings {
    guard !data.isEmpty, (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      throw InvalidSetting(data.isEmpty ? "the file is empty" : "not a JSON object")
    }
    return try JSONDecoder().decode(AppSettings.self, from: data)
  }

  static func describe(_ error: Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let c): return Self.path(c.codingPath) + c.debugDescription
    case DecodingError.typeMismatch(_, let c): return Self.path(c.codingPath) + c.debugDescription
    case DecodingError.valueNotFound(_, let c): return Self.path(c.codingPath) + c.debugDescription
    case DecodingError.keyNotFound(let k, let c): return Self.path(c.codingPath) + "missing \(k.stringValue)"
    default: return error.localizedDescription
    }
  }

  private static func path(_ keys: [CodingKey]) -> String {
    keys.isEmpty ? "" : keys.map(\.stringValue).joined(separator: ".") + ": "
  }

  // MARK: Write

  /// Sets one setting with the rules of `khuluma app-settings set`; the keys
  /// are the CLI's (`inline.autosend`, `app.hotkey`, ...). Refuses to write
  /// over a settings.json that doesn't parse. Returns the settings now saved.
  @discardableResult
  public func set(_ key: String, value: String,
                  directoryExists: (String) -> Bool = { SettingsEnvironment.isDirectory($0) },
                  home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> AppSettings {
    let change = try Self.validate(key, value, directoryExists: directoryExists, home: home)
    return try update { change(&$0) }
  }

  /// Creates settings.json if it's missing (the defaults), changing nothing else.
  public func ensureFile() throws {
    _ = try update { _ in }
  }

  /// Writes the whole settings document (keeping unknown keys already in the file).
  public func save(_ settings: AppSettings) throws {
    _ = try update { $0 = settings }
  }

  private func update(_ change: (inout AppSettings) -> Void) throws -> AppSettings {
    try DataFiles.ensureDirectory(folder)
    return try DataFiles.withLock(lockURL, timeout: lockTimeout) {
      var raw: [String: Any] = [:]
      var settings = AppSettings()
      // Only a genuinely missing file starts from the defaults; any other
      // read error leaves the file alone.
      let existing: Data?
      do {
        existing = try Data(contentsOf: url)
      } catch CocoaError.fileReadNoSuchFile {
        existing = nil
      } catch {
        throw InvalidSetting("settings.json is unreadable (\(error.localizedDescription)); not changing it")
      }
      if let data = existing {
        do {
          settings = try Self.decode(data)
          raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
          throw InvalidSetting("settings.json is invalid (\(Self.describe(error))); fix or remove it before changing settings")
        }
      }
      change(&settings)
      for (section, key) in Self.retiredKeys {
        if let section {
          if var inner = raw[section] as? [String: Any] { inner.removeValue(forKey: key); raw[section] = inner }
        } else {
          raw.removeValue(forKey: key)
        }
      }
      let data = try Self.encode(settings, over: raw)
      try DataFiles.replace(url, with: data)
      return settings
    }
  }

  /// The settings as JSON, deep-merged over `raw` so unknown keys survive.
  static func encode(_ settings: AppSettings, over raw: [String: Any]) throws -> Data {
    let typed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
    let merged = merge(raw, typed)
    var data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    return data
  }

  static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
    var out = base
    for (key, value) in over {
      if let a = base[key] as? [String: Any], let b = value as? [String: Any] {
        out[key] = merge(a, b)
      } else {
        out[key] = value
      }
    }
    return out
  }

  /// A `sounds.<event>.path` value: "" for the bundled default, else one
  /// absolute path to an existing regular file (after `~` expansion).
  static func validateSoundPath(_ value: String, home: String) throws {
    guard !value.contains("\n"), !value.contains("\r") else {
      throw InvalidSetting("sound path must be a single line")
    }
    guard !value.isEmpty else { return }
    guard value.hasPrefix("/") || value.hasPrefix("~") else {
      throw InvalidSetting("sound path must be absolute")
    }
    let expanded = value.hasPrefix("~") ? home + value.dropFirst() : value
    guard SettingsEnvironment.isRegularFile(expanded) else {
      throw InvalidSetting("sound path must be an existing file")
    }
  }

  /// The whole `inline.app_rules` list in one locked write, with the same
  /// rules the decoder applies (unique non-empty bundle ids, ≤ 100).
  @discardableResult
  public func setAppRules(_ rules: [AppSettings.AppRule]) throws -> AppSettings {
    guard rules.count <= 100 else { throw InvalidSetting("at most 100 app rules") }
    var seen = Set<String>()
    for rule in rules {
      guard !rule.bundleID.isEmpty, !rule.bundleID.contains("\n"), !rule.bundleID.contains("\r"),
            !rule.name.isEmpty, !rule.name.contains("\n"), !rule.name.contains("\r") else {
        throw InvalidSetting("app rules need a single-line bundle id and name")
      }
      guard seen.insert(rule.bundleID.lowercased()).inserted else {
        throw InvalidSetting("two rules name \(rule.bundleID)")
      }
    }
    return try update { $0.inline.appRules = rules }
  }

  /// One locked write for both halves of an event's sound choice, so a
  /// pop-up selection can't be torn between two saves.
  @discardableResult
  public func setSound(event: String, path: String, enabled: Bool,
                       home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> AppSettings {
    guard AppSettings.soundEvents.contains(event) else {
      throw InvalidSetting("unknown sound event \(event)")
    }
    try Self.validateSoundPath(path, home: home)
    return try update {
      $0.sounds.events[event] = AppSettings.Sound(enabled: enabled, path: path)
    }
  }

  /// The allowlist and validation of `app-settings set`.
  static func validate(_ key: String, _ value: String, directoryExists: (String) -> Bool,
                       home: String) throws -> (inout AppSettings) -> Void {
    func bool() throws -> Bool {
      switch value {
      case "true", "1": return true
      case "false", "0": return false
      default: throw InvalidSetting("setting value must be true or false")
      }
    }
    switch key {
    case "transcription.provider":
      guard value == "parakeet" || value == "elevenlabs" else { throw InvalidSetting("provider must be parakeet or elevenlabs") }
      return { $0.transcription.provider = value }
    case "transcription.language":
      guard value.range(of: "^(auto|[a-z]{2,3})$", options: .regularExpression) != nil else {
        throw InvalidSetting("language must be auto or an ISO 639 code such as en")
      }
      return { $0.transcription.language = value }
    case "transcription.scribe_tag_audio_events":
      let b = try bool(); return { $0.transcription.scribeTagAudioEvents = b }
    case "swift_parakeet.model_version":
      guard value.isEmpty || value == "v2" || value == "v3" else { throw InvalidSetting("model version must be v2 or v3") }
      return { $0.transcription.modelVersion = value }
    case "swift_parakeet.model_path":
      guard !value.contains("\n"), !value.contains("\r") else { throw InvalidSetting("model path must be a single line") }
      if !value.isEmpty {
        let expanded = value.hasPrefix("~") ? home + value.dropFirst() : value
        guard directoryExists(expanded) else { throw InvalidSetting("model path must be an existing directory") }
      }
      return { $0.transcription.modelPath = value }
    case "debug.keep_logs":
      let b = try bool(); return { $0.debug.keepLogs = b }
    case "history.retention_days":
      // 0 = forever. Lowering it below the audio days lowers those too.
      guard let n = Int(value), n >= 0 else { throw InvalidSetting("history retention must be 0 (forever) or more days") }
      return { $0.history.retentionDays = n
               $0.history.audioRetentionDays = HistoryRetention.clampedAudio($0.history.audioRetentionDays, history: n) }
    case "history.audio_retention_days":
      // 0 = off; never more than the history days.
      guard let n = Int(value), n >= 0 else { throw InvalidSetting("audio retention must be 0 (off) or more days") }
      return { $0.history.audioRetentionDays = HistoryRetention.clampedAudio(n, history: $0.history.retentionDays) }
    case "inline.autosend":
      let b = try bool(); return { $0.inline.autosend = b }
    case "inline.restore_clipboard":
      let b = try bool(); return { $0.inline.restoreClipboard = b }
    case "audio.sounds.enabled":
      let b = try bool(); return { $0.sounds.enabled = b }
    case "audio.sounds.start.enabled", "audio.sounds.stop.enabled", "audio.sounds.process.enabled",
         "audio.sounds.error.enabled", "audio.sounds.cancel.enabled":
      let b = try bool()
      let event = String(key.split(separator: ".")[2])
      return { $0.sounds.events[event]?.enabled = b }
    case "audio.sounds.start.path", "audio.sounds.stop.path", "audio.sounds.process.path",
         "audio.sounds.error.path", "audio.sounds.cancel.path":
      let event = String(key.split(separator: ".")[2])
      try Self.validateSoundPath(value, home: home)
      return { $0.sounds.events[event]?.path = value }
    case "clean.enabled":
      let b = try bool(); return { $0.cleanup.enabled = b }
    case "clean.spoken_formatting":
      let b = try bool(); return { $0.cleanup.spokenFormatting = b }
    case "clean.repeats_level":
      guard let level = Int(value), value.count == 1, (0...5).contains(level) else {
        throw InvalidSetting("repeat cleanup level must be between 0 and 5")
      }
      return { $0.cleanup.repeatsLevel = level }
    case "app.hotkey":
      guard AppSettings.isValidHotkey(value) else { throw InvalidSetting("invalid hotkey; use a modifier and key, or F1–F20") }
      return { $0.hotkey = value }
    default:
      throw InvalidSetting("setting is not editable through the app")
    }
  }
}
