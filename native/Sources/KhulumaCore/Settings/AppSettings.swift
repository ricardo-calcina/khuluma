import Foundation

/// The app's settings, stored as `settings.json` in the app folder
/// (`AppRuntimePaths.support`). Replaces the CLI's `config.toml`. Every field
/// has a default equal to what `khuluma app-config --json` resolved for an
/// empty config (environment overrides are gone with the CLI), so a missing
/// key means "default". Unknown keys in the file are kept by `SettingsStore`.
public struct AppSettings: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public static let fileName = "settings.json"
  public static let soundEvents = ["start", "stop", "process", "error", "cancel"]

  public struct Sound: Codable, Equatable, Sendable {
    public var enabled = true
    /// "" = the default `<sounds dir>/<event>.wav`. `~` and `$SOUNDS_DIR`
    /// expand as the CLI expanded them.
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

  public struct Inline: Codable, Equatable, Sendable {
    public var autosend = true
    /// enter, ctrl_j or cmd_enter.
    public var sendMode = "enter"
    /// current or restore.
    public var pasteTarget = "current"
    public var processSound = true
    public var activateDelayMs = 90
    public var sendDelayMs = 35
    public init() {}

    enum CodingKeys: String, CodingKey {
      case autosend
      case sendMode = "send_mode"
      case pasteTarget = "paste_target"
      case processSound = "process_sound"
      case activateDelayMs = "activate_delay_ms"
      case sendDelayMs = "send_delay_ms"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      autosend = try c.decodeIfPresent(Bool.self, forKey: .autosend) ?? true
      sendMode = AppSettings.normalizedSendMode(try c.decodeIfPresent(String.self, forKey: .sendMode) ?? "enter")
      pasteTarget = AppSettings.normalizedPasteTarget(try c.decodeIfPresent(String.self, forKey: .pasteTarget) ?? "current")
      processSound = try c.decodeIfPresent(Bool.self, forKey: .processSound) ?? true
      activateDelayMs = max(0, try c.decodeIfPresent(Int.self, forKey: .activateDelayMs) ?? 90)
      sendDelayMs = max(0, try c.decodeIfPresent(Int.self, forKey: .sendDelayMs) ?? 35)
    }
  }

  public struct Cleanup: Codable, Equatable, Sendable {
    /// Filler removal (`[clean] enabled`).
    public var enabled = false
    /// 0-3 (`[clean] repeats_level`).
    public var repeatsLevel = 1
    /// Vocabulary corrections.
    public var vocabulary = true
    public var britishSpelling = true
    public init() {}

    enum CodingKeys: String, CodingKey {
      case enabled
      case repeatsLevel = "repeats_level"
      case vocabulary
      case britishSpelling = "british_spelling"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
      repeatsLevel = try c.decodeIfPresent(Int.self, forKey: .repeatsLevel) ?? 1
      guard (0...3).contains(repeatsLevel) else {
        throw DecodingError.dataCorruptedError(forKey: .repeatsLevel, in: c, debugDescription: "repeats_level must be 0-3")
      }
      vocabulary = try c.decodeIfPresent(Bool.self, forKey: .vocabulary) ?? true
      britishSpelling = try c.decodeIfPresent(Bool.self, forKey: .britishSpelling) ?? true
    }
  }

  public struct Transcription: Codable, Equatable, Sendable {
    /// parakeet or elevenlabs.
    public var provider = "parakeet"
    /// auto or an ISO 639 code.
    public var language = "en"
    /// "" = the newest model in the models folder.
    public var modelPath = ""
    /// "", v2 or v3 ("" = from the model folder's name).
    public var modelVersion = ""
    /// "" = the daemon's default socket.
    public var socketPath = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
      case provider, language
      case modelPath = "model_path"
      case modelVersion = "model_version"
      case socketPath = "socket_path"
    }

    public init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "parakeet"
      guard provider == "parakeet" || provider == "elevenlabs" else {
        throw DecodingError.dataCorruptedError(forKey: .provider, in: c, debugDescription: "provider must be parakeet or elevenlabs")
      }
      language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
      modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
      modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion) ?? ""
      socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath) ?? ""
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
    public var retentionDays = 7
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
  /// Set by the import when the CLI's config couldn't be converted: the
  /// settings are defaults with autosend off, and the app warns until a
  /// setting is changed in the app.
  public var importWarning: String?

  public init() {}

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case hotkey, sounds, inline, cleanup, transcription, app, debug, history
    case importWarning = "import_warning"
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
    importWarning = try c.decodeIfPresent(String.self, forKey: .importWarning)
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

/// What the settings resolve against on this Mac: folders and tool presence.
/// Injected so tests (and the parity fixtures) never touch real folders.
public struct SettingsEnvironment: Sendable {
  /// The app folder: vocabulary.json and usage.json live here.
  public var appFolder: URL
  /// `$HOME`, for `~` in paths.
  public var home: String
  /// Default sounds: `<soundsDir>/<event>.wav` (the CLI's `KHULUMA_SOUNDS_DIR`).
  public var soundsDir: String
  /// `$SOUNDS_DIR` placeholder value in sound paths (the CLI's `SOUNDS_DIR`), if any.
  public var soundsPlaceholder: String?
  /// Where installed Parakeet models live.
  public var modelsDir: String
  /// The daemon socket when the settings name none.
  public var defaultSocketPath: String
  public var processingDir: String
  public var ffmpegAvailable: Bool
  public var keyAvailable: Bool
  public var fileExists: @Sendable (String) -> Bool
  public var directoryExists: @Sendable (String) -> Bool

  public init(appFolder: URL, home: String, soundsDir: String, soundsPlaceholder: String? = nil, modelsDir: String,
              defaultSocketPath: String, processingDir: String = TakeMarker.defaultDirectory,
              ffmpegAvailable: Bool, keyAvailable: Bool,
              fileExists: @escaping @Sendable (String) -> Bool = SettingsEnvironment.isRegularFile,
              directoryExists: @escaping @Sendable (String) -> Bool = SettingsEnvironment.isDirectory) {
    self.appFolder = appFolder
    self.home = home
    self.soundsDir = soundsDir
    self.soundsPlaceholder = soundsPlaceholder
    self.modelsDir = modelsDir
    self.defaultSocketPath = defaultSocketPath
    self.processingDir = processingDir
    self.ffmpegAvailable = ffmpegAvailable
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

  /// This Mac, with the folders the CLI's installer used (sounds, models and
  /// the daemon's socket stay where they are until later slices move them).
  public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             appFolder: URL = AppRuntimePaths.support) -> SettingsEnvironment {
    func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
    let data = value("XDG_DATA_HOME") ?? home.appendingPathComponent(".local/share").path
    let legacy = LegacyImport.source(environment: environment, home: home).root
    let tools = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (value("PATH")?.split(separator: ":").map(String.init) ?? [])
    let has = { (name: String) in tools.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) } }
    // `$SOUNDS_DIR` in sound paths means what it meant to the CLI: the
    // SOUNDS_DIR variable, else ~/.local/share/sounds (the parent of the
    // default khuluma sounds folder). Slice D moves sounds into the bundle.
    let soundsParent = value("SOUNDS_DIR") ?? data + "/sounds"
    return SettingsEnvironment(
      appFolder: appFolder, home: home.path,
      soundsDir: soundsParent + "/khuluma", soundsPlaceholder: soundsParent,
      modelsDir: data + "/khuluma/models",
      defaultSocketPath: legacy.appendingPathComponent(".cache/khulumad.sock").path,
      ffmpegAvailable: has("ffmpeg") && has("ffprobe"),
      // Presence only, from the environment; the Keychain and zshrc lookup
      // come with native ElevenLabs (slice E).
      keyAvailable: ["ELEVENLABS_API_KEY", "ELEVEN_LABS_API_KEY"].contains { value($0)?.trimmingCharacters(in: .whitespaces).isEmpty == false })
  }

  /// `expand_path`: a leading `~` becomes `$HOME`.
  public func expand(_ path: String) -> String {
    path.hasPrefix("~") ? home + path.dropFirst() : path
  }

  func expandSound(_ path: String) -> String {
    var p = expand(path)
    if let placeholder = soundsPlaceholder, !placeholder.isEmpty {
      p = p.replacingOccurrences(of: "${SOUNDS_DIR}", with: placeholder).replacingOccurrences(of: "$SOUNDS_DIR", with: placeholder)
    }
    return p
  }
}

extension AppSettings {
  /// `khuluma_sound_path`: the configured file, else `<soundsDir>/<event>.wav`,
  /// and only if it exists.
  public func soundPath(_ event: String, in env: SettingsEnvironment) -> String? {
    let configured = sounds.sound(event).path
    let path = configured.isEmpty ? env.soundsDir + "/" + event + ".wav" : env.expandSound(configured)
    return env.fileExists(path) ? path : nil
  }

  /// `resolve_swift_parakeet_model_path`.
  public func resolvedModelPath(in env: SettingsEnvironment) -> String? {
    if !transcription.modelPath.isEmpty { return env.expand(transcription.modelPath) }
    for name in ["parakeet-tdt-0.6b-v3-coreml", "parakeet-tdt-0.6b-v2-coreml"] {
      let candidate = env.modelsDir + "/" + name
      if env.directoryExists(candidate) { return candidate }
    }
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
  /// The fixed `cli_version` of a config built from settings.json (slice G
  /// removes the field).
  public static let nativeCLIVersion = "app"

  /// The app's settings as the in-memory model the rest of the app reads,
  /// equal to what `khuluma app-config --json` reported for the same
  /// settings. `status` says where the settings came from.
  public init(settings s: AppSettings, status: ConfigStatus = ConfigStatus(error: nil, source: "file"),
              environment env: SettingsEnvironment) {
    var sounds: [String: Sound] = [:]
    for event in AppSettings.soundEvents {
      let path = s.soundPath(event, in: env)
      let on = s.sounds.enabled && s.sounds.sound(event).enabled
      sounds[event] = Sound(enabled: on && path != nil, path: path)
    }
    // No trustworthy settings (invalid file with no valid copy, an import
    // that couldn't convert the CLI's config): never send.
    let autosend = s.inline.autosend && !(status.error != nil && status.source != "last_good")
    let inline = Inline(autosend: autosend, sendMode: s.inline.sendMode, pasteTarget: s.inline.pasteTarget,
                        processSound: s.inline.processSound, activateDelayMs: s.inline.activateDelayMs,
                        sendDelayMs: s.inline.sendDelayMs)
    let cleanup = CleanupSettings(configDir: env.appFolder.path, clean: s.cleanup.enabled ? "1" : "0",
                                  repeatsLevel: String(s.cleanup.repeatsLevel),
                                  vocabClean: s.cleanup.vocabulary ? "1" : "0",
                                  britishSpelling: s.cleanup.britishSpelling ? "1" : "0",
                                  localeCtype: "", localeCollate: "")
    let cloud = s.transcription.provider == "elevenlabs"
    let modelPath = s.resolvedModelPath(in: env)
    let label = cloud ? "scribe_v2" : modelPath.map { ($0 as NSString).lastPathComponent } ?? "parakeet-unresolved"
    let socket = s.transcription.socketPath.isEmpty ? env.defaultSocketPath : env.expand(s.transcription.socketPath)
    let transcription = TranscriptionSettings(
      socketPath: socket, modelPath: modelPath,
      modelVersion: modelPath.map { AppSettings.modelVersion(explicit: s.transcription.modelVersion, modelPath: $0) },
      modelLabel: label, language: s.transcription.language, tailPadMs: "500", tailRescue: true,
      tailRescueMs: "", tailRescueMinMs: "", keepLogs: s.debug.keepLogs, ffmpeg: env.ffmpegAvailable,
      timeoutSeconds: "600", processingDir: env.processingDir, provider: s.transcription.provider,
      keyAvailable: env.keyAvailable)
    self.init(schemaVersion: 1, appContract: AppContract.version, cliVersion: AppConfig.nativeCLIVersion,
              hotkey: s.hotkey, sounds: sounds, soundsEnabled: s.sounds.enabled, inline: inline, cleanup: cleanup,
              transcription: transcription, pipeline: Pipeline(supervise: s.app.superviseDaemon && !cloud),
              config: status, usage: Usage(summaryPath: env.appFolder.appendingPathComponent("usage.json").path))
  }
}
