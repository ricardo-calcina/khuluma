import Foundation

/// The app's settings, stored as `settings.json` in the app folder
/// (`AppRuntimePaths.support`). Every field has a default, so a missing key
/// means "default". Unknown keys in the file are kept by `SettingsStore`.
public struct AppSettings: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public static let fileName = "settings.json"
  public static let soundEvents = ["start", "stop", "process", "error", "cancel"]

  public struct Sound: Codable, Equatable, Sendable {
    public var enabled = true
    /// "" = the bundled default `<event>.wav`; else an absolute path (a
    /// leading `~` expands to the home folder).
    public var path = ""
    public init(enabled: Bool = true, path: String = "") { self.enabled = enabled; self.path = path }
    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
      path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
  }

  public struct Sounds: Codable, Equatable, Sendable {
    /// The master switch.
    public var enabled = true
    public var events: [String: Sound] = Dictionary(uniqueKeysWithValues: AppSettings.soundEvents.map { ($0, Sound()) })
    public init() {}

    public func sound(_ event: String) -> Sound { events[event] ?? Sound() }

    struct Key: CodingKey {
      var stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: Key.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: Key(stringValue: "enabled")) ?? true
      for event in AppSettings.soundEvents {
        events[event] = try c.decodeIfPresent(Sound.self, forKey: Key(stringValue: event)) ?? Sound()
      }
    }

    public func encode(to e: Encoder) throws {
      var c = e.container(keyedBy: Key.self)
      try c.encode(enabled, forKey: Key(stringValue: "enabled"))
      for event in AppSettings.soundEvents { try c.encode(sound(event), forKey: Key(stringValue: event)) }
    }
  }

  /// One per-app auto-send rule: an app's bundle id, its display name for
  /// the list, and whether dictations pasted into it send.
  public struct AppRule: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var autosend: Bool
    public init(bundleID: String, name: String, autosend: Bool) {
      self.bundleID = bundleID
      self.name = name
      self.autosend = autosend
    }
    enum CodingKeys: String, CodingKey {
      case bundleID = "bundle_id"
      case name, autosend
    }
  }

  /// Rules with a real, unique bundle id (case-insensitive), capped at 100.
  public static func sanitizedAppRules(_ rules: [AppRule]) -> [AppRule] {
    var seen = Set<String>()
    var out: [AppRule] = []
    for rule in rules where !rule.bundleID.isEmpty {
      guard seen.insert(rule.bundleID.lowercased()).inserted else { continue }
      out.append(rule)
      if out.count == 100 { break }
    }
    return out
  }

  public struct Inline: Codable, Equatable, Sendable {
    public var autosend = true
    /// enter, ctrl_j or cmd_enter.
    public var sendMode = "enter"
    /// current or restore.
    public var pasteTarget = "current"
    public var processSound = true
    public var activateDelayMs = 90
    public var sendDelayMs = 35
    /// Put back what was on the clipboard after a successful paste.
    public var restoreClipboard = false
    /// Per-app auto-send rules, matching the pasted-into app's bundle id.
    public var appRules: [AppRule] = []
    public init() {}

    enum CodingKeys: String, CodingKey {
      case autosend
      case sendMode = "send_mode"
      case pasteTarget = "paste_target"
      case processSound = "process_sound"
      case activateDelayMs = "activate_delay_ms"
      case sendDelayMs = "send_delay_ms"
      case restoreClipboard = "restore_clipboard"
      case appRules = "app_rules"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      autosend = try c.decodeIfPresent(Bool.self, forKey: .autosend) ?? true
      sendMode = AppSettings.normalizedSendMode(try c.decodeIfPresent(String.self, forKey: .sendMode) ?? "enter")
      pasteTarget = AppSettings.normalizedPasteTarget(try c.decodeIfPresent(String.self, forKey: .pasteTarget) ?? "current")
      processSound = try c.decodeIfPresent(Bool.self, forKey: .processSound) ?? true
      activateDelayMs = max(0, try c.decodeIfPresent(Int.self, forKey: .activateDelayMs) ?? 90)
      sendDelayMs = max(0, try c.decodeIfPresent(Int.self, forKey: .sendDelayMs) ?? 35)
      restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? false
      appRules = AppSettings.sanitizedAppRules(try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? [])
    }
  }

  public struct Cleanup: Codable, Equatable, Sendable {
    /// Filler removal (`[clean] enabled`).
    public var enabled = false
    /// 0-5 (`[clean] repeats_level`).
    public var repeatsLevel = 1
    /// Vocabulary corrections.
    public var vocabulary = true
    public var britishSpelling = true
    /// Spoken "new line" / "new paragraph" become breaks (app-only).
    public var spokenFormatting = false
    public init() {}

    enum CodingKeys: String, CodingKey {
      case enabled
      case repeatsLevel = "repeats_level"
      case vocabulary
      case britishSpelling = "british_spelling"
      case spokenFormatting = "spoken_formatting"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
      repeatsLevel = try c.decodeIfPresent(Int.self, forKey: .repeatsLevel) ?? 1
      guard (0...5).contains(repeatsLevel) else {
        throw DecodingError.dataCorruptedError(forKey: .repeatsLevel, in: c, debugDescription: "repeats_level must be 0-5")
      }
      vocabulary = try c.decodeIfPresent(Bool.self, forKey: .vocabulary) ?? true
      britishSpelling = try c.decodeIfPresent(Bool.self, forKey: .britishSpelling) ?? true
      spokenFormatting = try c.decodeIfPresent(Bool.self, forKey: .spokenFormatting) ?? false
    }
  }

  public struct Transcription: Codable, Equatable, Sendable {
    /// parakeet or elevenlabs.
    public var provider = "parakeet"
    /// auto or an ISO 639 code.
    public var language = "en"
    public var scribeTagAudioEvents = true
    /// "" = FluidAudio's shared cache (downloaded on first run). Used only
    /// when this folder exists.
    public var modelPath = ""
    /// "", v2 or v3 ("" = from the model folder's name).
    public var modelVersion = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
      case provider, language
      case scribeTagAudioEvents = "scribe_tag_audio_events"
      case modelPath = "model_path"
      case modelVersion = "model_version"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "parakeet"
      guard provider == "parakeet" || provider == "elevenlabs" else {
        throw DecodingError.dataCorruptedError(forKey: .provider, in: c, debugDescription: "provider must be parakeet or elevenlabs")
      }
      language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
      scribeTagAudioEvents = try c.decodeIfPresent(Bool.self, forKey: .scribeTagAudioEvents) ?? true
      modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
      modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion) ?? ""
    }
  }

  public struct App: Codable, Equatable, Sendable {
    /// Keep the Parakeet daemon warm.
    public var superviseDaemon = true
    public init() {}
    enum CodingKeys: String, CodingKey { case superviseDaemon = "supervise_daemon" }
    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      superviseDaemon = try c.decodeIfPresent(Bool.self, forKey: .superviseDaemon) ?? true
    }
  }

  public struct Debug: Codable, Equatable, Sendable {
    public var keepLogs = false
    public init() {}
    enum CodingKeys: String, CodingKey { case keepLogs = "keep_logs" }
    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      keepLogs = try c.decodeIfPresent(Bool.self, forKey: .keepLogs) ?? false
    }
  }

  public struct History: Codable, Equatable, Sendable {
    /// Days of history; 0 keeps it forever (HistoryRetention).
    public var retentionDays = 7
    /// Days archived WAVs are kept (only while keep_logs is on); 0 = off.
    public var audioRetentionDays = 2
    /// Assumed typing pace for time-saved estimates.
    public var typingWpm = 40
    public init() {}

    enum CodingKeys: String, CodingKey {
      case retentionDays = "retention_days"
      case audioRetentionDays = "audio_retention_days"
      case typingWpm = "typing_wpm"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
      audioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? 2
      typingWpm = try c.decodeIfPresent(Int.self, forKey: .typingWpm) ?? 40
      if typingWpm <= 0 { typingWpm = 40 }
    }
  }

  public var schemaVersion = AppSettings.schemaVersion
  public var hotkey = "ctrl+option+space"
  public var sounds = Sounds()
  public var inline = Inline()
  public var cleanup = Cleanup()
  public var transcription = Transcription()
  public var app = App()
  public var debug = Debug()
  public var history = History()

  public init() {}

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case hotkey, sounds, inline, cleanup, transcription, app, debug, history
  }

  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AppSettings.schemaVersion
    guard schemaVersion == AppSettings.schemaVersion else {
      throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                                             debugDescription: "schema_version \(schemaVersion) is not \(AppSettings.schemaVersion)")
    }
    hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "ctrl+option+space"
    sounds = try c.decodeIfPresent(Sounds.self, forKey: .sounds) ?? Sounds()
    inline = try c.decodeIfPresent(Inline.self, forKey: .inline) ?? Inline()
    cleanup = try c.decodeIfPresent(Cleanup.self, forKey: .cleanup) ?? Cleanup()
    transcription = try c.decodeIfPresent(Transcription.self, forKey: .transcription) ?? Transcription()
    app = try c.decodeIfPresent(App.self, forKey: .app) ?? App()
    debug = try c.decodeIfPresent(Debug.self, forKey: .debug) ?? Debug()
    history = try c.decodeIfPresent(History.self, forKey: .history) ?? History()
  }

  /// `normalize_inline_send_mode`.
  public static func normalizedSendMode(_ value: String) -> String {
    switch value {
    case "ctrl_j", "ctrl-j", "ctrlj", "ctrl+j": return "ctrl_j"
    case "cmd_enter", "cmd-enter", "cmdenter", "cmd+enter": return "cmd_enter"
    default: return "enter"
    }
  }

  /// `normalize_inline_paste_target`: only "current" stays; anything else
  /// (origin, restore, unknown) restores the original app.
  public static func normalizedPasteTarget(_ value: String) -> String {
    value == "current" ? "current" : "restore"
  }

  /// The hotkey rule of `khuluma app-settings set app.hotkey`: one key plus
  /// at least one modifier, or a bare F1-F20.
  public static func isValidHotkey(_ value: String) -> Bool {
    let parts = value.split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    let modifiers: Set<String> = ["ctrl", "control", "⌃", "option", "opt", "alt", "⌥", "shift", "⇧", "cmd", "command", "⌘"]
    var keys = Set("abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./".map(String.init))
    keys.formUnion(["grave", "space", "return", "enter", "tab", "escape", "esc", "delete", "backspace", "left", "right", "down", "up"])
    let functions = Set((1...20).map { "f\($0)" })
    let pressed = parts.filter { !modifiers.contains($0) }
    guard pressed.count == 1 else { return false }
    return functions.contains(pressed[0]) || (keys.contains(pressed[0]) && parts.count > 1)
  }
}

// MARK: - Resolving settings into the app's AppConfig

/// What the settings resolve against on this Mac: folders and the key check.
/// Injected so tests never touch real folders.
public struct SettingsEnvironment: Sendable {
  /// The app folder: vocabulary.json and usage.json live here.
  public var appFolder: URL
  /// `$HOME`, for `~` in paths.
  public var home: String
  /// The app's bundled default sounds (`Khuluma.app/Contents/Resources/sounds`),
  /// nil when not running from a bundle (swift test, dev runs).
  public var bundledSoundsDir: String?
  /// The daemon socket when the settings name none.
  public var defaultSocketPath: String
  /// FluidAudio's default cache folder for Parakeet v3 (the app sets it from
  /// FluidAudio's own API; nil in tests unless set).
  public var defaultModelPath: String?
  /// Isolated runs: a configured model folder here is real data (e.g.
  /// FluidAudio's shared cache) and is ignored in favour of the isolated default.
  public var isForbiddenModelPath: @Sendable (String) -> Bool = { _ in false }
  /// A complete model of this version ("v2"/"v3") is in this folder (the
  /// app checks the files FluidAudio loads for that version).
  public var modelAvailable: @Sendable (_ path: String, _ version: String) -> Bool = { path, _ in
    SettingsEnvironment.isDirectory(path)
  }
  public var processingDir: String
  public var keyAvailable: Bool
  /// Looks the ElevenLabs key up afresh at each settings load (Keychain, then
  /// shell settings); presence only. Overrides `keyAvailable` when set.
  public var keyCheck: (@Sendable () -> Bool)?
  public var fileExists: @Sendable (String) -> Bool
  public var directoryExists: @Sendable (String) -> Bool

  public init(appFolder: URL, home: String, bundledSoundsDir: String? = nil,
              defaultSocketPath: String, processingDir: String = TakeMarker.defaultDirectory,
              keyAvailable: Bool,
              fileExists: @escaping @Sendable (String) -> Bool = SettingsEnvironment.isRegularFile,
              directoryExists: @escaping @Sendable (String) -> Bool = SettingsEnvironment.isDirectory) {
    self.appFolder = appFolder
    self.home = home
    self.bundledSoundsDir = bundledSoundsDir
    self.defaultSocketPath = defaultSocketPath
    self.processingDir = processingDir
    self.keyAvailable = keyAvailable
    self.fileExists = fileExists
    self.directoryExists = directoryExists
  }

  public static let isRegularFile: @Sendable (String) -> Bool = { path in
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
  }

  public static let isDirectory: @Sendable (String) -> Bool = { path in
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
  }

  /// This Mac: the app folder, the bundled sounds and the app's own daemon socket.
  public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             appFolder: URL = AppRuntimePaths.support) -> SettingsEnvironment {
    var result = SettingsEnvironment(
      appFolder: appFolder, home: home.path,
      bundledSoundsDir: Bundle.main.resourceURL?.appendingPathComponent("sounds", isDirectory: true).path,
      defaultSocketPath: DaemonSocketPath.resolve(support: appFolder).path,
      // Presence only: the Keychain, then the environment and zshrc, at
      // each settings load (`keyCheck`).
      keyAvailable: false)
    result.keyCheck = { ScribeCredential(environment: environment, home: home).isAvailable }
    if AppRuntimePaths.isIsolated(environment: environment) {
      result.isForbiddenModelPath = { AppRuntimePaths.isRealData($0, home: home) }
    }
    return result
  }

  /// A leading `~` becomes `$HOME`.
  public func expand(_ path: String) -> String {
    path.hasPrefix("~") ? home + path.dropFirst() : path
  }

  /// `<bundled>/<name>` when it exists.
  func bundledSound(_ name: String) -> String? {
    guard let dir = bundledSoundsDir, !dir.isEmpty, !name.isEmpty, !name.contains("/") else { return nil }
    let path = dir + "/" + name
    return fileExists(path) ? path : nil
  }
}

extension AppSettings {
  /// The sound file for an event, and only if it exists; nil is silent.
  /// No path set: the bundled `sounds/<event>.wav`. A path set (usually a
  /// file in the app's sounds folder, `SoundLibrary`): that file, `~` expanded.
  public func soundPath(_ event: String, in env: SettingsEnvironment) -> String? {
    let configured = sounds.sound(event).path
    if configured.isEmpty { return env.bundledSound(event + ".wav") }
    let path = env.expand(configured)
    return env.fileExists(path) ? path : nil
  }

  /// `resolve_swift_parakeet_model_path`.
  public func resolvedModelPath(in env: SettingsEnvironment) -> String? {
    resolvedModel(in: env)?.path
  }

  /// The model folder and its version, resolved together: the settings'
  /// folder (with the settings' version, if any) if it holds a model, else
  /// `defaultModelPath` (FluidAudio's shared cache, or the isolated run's
  /// own folder, see `AppRuntimePaths.defaultModelDirectory`), always v3 (an
  /// explicit v2 meant for the missing folder doesn't carry over).
  public func resolvedModel(in env: SettingsEnvironment) -> (path: String, version: String)? {
    if !transcription.modelPath.isEmpty, !env.isForbiddenModelPath(env.expand(transcription.modelPath)) {
      let configured = env.expand(transcription.modelPath)
      // Checked as the version it resolves to (an explicit v2 in a custom
      // folder name is still v2).
      let version = AppSettings.modelVersion(explicit: transcription.modelVersion, modelPath: configured)
      if env.modelAvailable(configured, version) { return (configured, version) }
    }
    if let fallback = env.defaultModelPath, env.modelAvailable(fallback, "v3") { return (fallback, "v3") }
    return nil
  }



  /// `resolve_swift_parakeet_model_version`.
  public static func modelVersion(explicit: String, modelPath: String) -> String {
    let v = explicit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if v == "v2" || v == "v3" { return v }
    let base = (modelPath as NSString).lastPathComponent
    if base.contains("v2") || base.contains("V2") { return "v2" }
    return "v3"
  }
}

extension AppConfig {
  /// The app's settings as the in-memory model the rest of the app reads.
  /// `status` says where the settings came from.
  public init(settings s: AppSettings, status: ConfigStatus = ConfigStatus(error: nil, source: "file"),
              environment env: SettingsEnvironment) {
    var sounds: [String: Sound] = [:]
    for event in AppSettings.soundEvents {
      let path = s.soundPath(event, in: env)
      let on = s.sounds.enabled && s.sounds.sound(event).enabled
      sounds[event] = Sound(enabled: on && path != nil, path: path)
    }
    // No trustworthy settings (invalid file with no valid copy): never send.
    let autosend = s.inline.autosend && !(status.error != nil && status.source != "last_good")
    let inline = Inline(autosend: autosend, sendMode: s.inline.sendMode, pasteTarget: s.inline.pasteTarget,
                        processSound: s.inline.processSound, activateDelayMs: s.inline.activateDelayMs,
                        sendDelayMs: s.inline.sendDelayMs, restoreClipboard: s.inline.restoreClipboard,
                        appRules: s.inline.appRules)
    var cleanup = CleanupSettings(configDir: env.appFolder.path, clean: s.cleanup.enabled ? "1" : "0",
                                  repeatsLevel: String(s.cleanup.repeatsLevel),
                                  vocabClean: s.cleanup.vocabulary ? "1" : "0",
                                  britishSpelling: s.cleanup.britishSpelling ? "1" : "0",
                                  localeCtype: "", localeCollate: "")
    if s.cleanup.spokenFormatting { cleanup.spokenFormatting = "1" }  // nil when off, as the CLI reports it
    let cloud = s.transcription.provider == "elevenlabs"
    let model = s.resolvedModel(in: env)
    let modelPath = model?.path
    let label = cloud ? "scribe_v2" : modelPath.map { ($0 as NSString).lastPathComponent } ?? "parakeet-unresolved"
    let transcription = TranscriptionSettings(
      socketPath: env.defaultSocketPath, modelPath: modelPath,
      modelVersion: model?.version,
      modelLabel: label, language: s.transcription.language, tailPadMs: "500", tailRescue: true,
      tailRescueMs: "", tailRescueMinMs: "", keepLogs: s.debug.keepLogs,
      timeoutSeconds: "600", processingDir: env.processingDir, provider: s.transcription.provider,
      keyAvailable: env.keyCheck?() ?? env.keyAvailable, scribeTagAudioEvents: s.transcription.scribeTagAudioEvents)
    self.init(schemaVersion: 1, hotkey: s.hotkey, sounds: sounds, soundsEnabled: s.sounds.enabled, inline: inline, cleanup: cleanup,
              transcription: transcription, pipeline: Pipeline(supervise: s.app.superviseDaemon && !cloud),
              config: status, usage: Usage(summaryPath: env.appFolder.appendingPathComponent("usage.json").path))
  }
}
