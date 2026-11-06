import Foundation

/// The app's resolved settings (from settings.json, see
/// `AppConfig.init(settings:environment:)`), in the shape the app has always
/// consumed.
public struct AppConfig: Decodable, Equatable, Sendable {
  public struct Sound: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let path: String?

    public init(enabled: Bool, path: String?) {
      self.enabled = enabled
      self.path = path
    }
  }

  public struct Inline: Decodable, Equatable, Sendable {
    public let autosend: Bool
    public let sendMode: String
    public let pasteTarget: String
    public let processSound: Bool
    public let activateDelayMs: Int
    public let sendDelayMs: Int

    public init(autosend: Bool, sendMode: String, pasteTarget: String, processSound: Bool,
                activateDelayMs: Int, sendDelayMs: Int) {
      self.autosend = autosend
      self.sendMode = sendMode
      self.pasteTarget = pasteTarget
      self.processSound = processSound
      self.activateDelayMs = activateDelayMs
      self.sendDelayMs = sendDelayMs
    }

    enum CodingKeys: String, CodingKey {
      case autosend
      case sendMode = "send_mode"
      case pasteTarget = "paste_target"
      case processSound = "process_sound"
      case activateDelayMs = "activate_delay_ms"
      case sendDelayMs = "send_delay_ms"
    }
  }

  public let schemaVersion: Int
  public let hotkey: String
  public let sounds: [String: Sound]
  private let declaredSoundsEnabled: Bool?
  /// The global sound switch, independent of missing or disabled events.
  public var soundsEnabled: Bool { declaredSoundsEnabled ?? true }
  public let inline: Inline
  /// Text cleanup settings for the native TextPipeline.
  public let cleanup: CleanupSettings
  /// Transcription settings for the native path.
  public let transcription: TranscriptionSettings
  public let pipeline: Pipeline
  /// Whether config.toml parsed.
  public let config: ConfigStatus
  /// Where the usage ledger lives.
  public let usage: Usage

  public struct Usage: Decodable, Equatable, Sendable {
    public let summaryPath: String

    public init(summaryPath: String) { self.summaryPath = summaryPath }

    enum CodingKeys: String, CodingKey {
      case summaryPath = "summary_path"
    }
  }

  public struct ConfigStatus: Decodable, Equatable, Sendable {
    /// The TOML parse error, if config.toml is invalid.
    public let error: String?
    /// "file", or when invalid: "last_good" (last valid copy) or "defaults".
    public let source: String

    public init(error: String?, source: String) {
      self.error = error
      self.source = source
    }
  }

  /// config.toml is invalid and there was no valid copy to fall back to, so
  /// the settings are the built-in defaults rather than the user's.
  public var usingFallbackDefaults: Bool {
    guard config.error != nil else { return false }
    return config.source != "last_good"
  }

  /// Delivery settings made safe: with fallback defaults, never press a send
  /// key the user may have turned off (autosend defaults to on).
  public func safeDelivery(_ delivery: Delivery) -> Delivery {
    guard usingFallbackDefaults, delivery.autosend else { return delivery }
    return Delivery(autosend: false, sendMode: delivery.sendMode, pasteTarget: delivery.pasteTarget,
                    activateDelayMs: delivery.activateDelayMs, sendDelayMs: delivery.sendDelayMs)
  }

  public struct Pipeline: Decodable, Equatable, Sendable {
    /// `[app] supervise_daemon`.
    public let supervise: Bool

    public init(supervise: Bool) { self.supervise = supervise }
  }

  public init(schemaVersion: Int, hotkey: String, sounds: [String: Sound],
              soundsEnabled: Bool?, inline: Inline, cleanup: CleanupSettings, transcription: TranscriptionSettings,
              pipeline: Pipeline, config: ConfigStatus, usage: Usage) {
    self.schemaVersion = schemaVersion
    self.hotkey = hotkey
    self.sounds = sounds
    self.declaredSoundsEnabled = soundsEnabled
    self.inline = inline
    self.cleanup = cleanup
    self.transcription = transcription
    self.pipeline = pipeline
    self.config = config
    self.usage = usage
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case hotkey
    case sounds
    case declaredSoundsEnabled = "sounds_enabled"
    case inline
    case cleanup
    case transcription
    case pipeline
    case config
    case usage
  }

  /// Why Khuluma must not keep its daemon warm, or nil if it may. The app
  /// owns its daemon now and takes need it, so `supervise_daemon` (a CLI-era
  /// switch for the CLI's shared daemon) no longer turns it off.
  public var supervisionBlocker: String? {
    guard transcription.provider == "parakeet" else { return "cloud transcription selected" }
    guard transcription.modelPath?.isEmpty == false else { return TranscriptionSettings.modelMissing }
    return nil
  }

  /// The delivery settings (made safe when settings.json is invalid with no
  /// last valid copy).
  public var delivery: Delivery {
    safeDelivery(Delivery(autosend: inline.autosend, sendMode: inline.sendMode, pasteTarget: inline.pasteTarget,
                          activateDelayMs: inline.activateDelayMs, sendDelayMs: inline.sendDelayMs))
  }

  /// Why takes can't be transcribed with these settings right now (they are
  /// kept in recovered/ until they can), or nil if they can.
  public var nativePipelineBlocker: String? {
    transcription.blocker
  }

  /// What the native path needs, or nil when it can't run (see
  /// `nativePipelineBlocker`, and a missing model path).
  public var native: (transcription: TranscriptionSettings, cleanup: CleanupSettings, modelPath: String)? {
    guard transcription.provider == "parakeet", nativePipelineBlocker == nil,
          let modelPath = transcription.modelPath else { return nil }
    return (transcription, cleanup, modelPath)
  }

  /// What the native ElevenLabs Scribe route needs, or nil when Scribe isn't chosen.
  public var scribe: (transcription: TranscriptionSettings, cleanup: CleanupSettings)? {
    transcription.provider == "elevenlabs" ? (transcription, cleanup) : nil
  }
}

public struct Delivery: Decodable, Equatable, Sendable {
  public let autosend: Bool
  public let sendMode: String
  public let pasteTarget: String
  public let activateDelayMs: Int
  public let sendDelayMs: Int

  public init(autosend: Bool, sendMode: String, pasteTarget: String, activateDelayMs: Int, sendDelayMs: Int) {
    self.autosend = autosend
    self.sendMode = sendMode
    self.pasteTarget = pasteTarget
    self.activateDelayMs = activateDelayMs
    self.sendDelayMs = sendDelayMs
  }

  enum CodingKeys: String, CodingKey {
    case autosend
    case sendMode = "send_mode"
    case pasteTarget = "paste_target"
    case activateDelayMs = "activate_delay_ms"
    case sendDelayMs = "send_delay_ms"
  }

  /// The same delivery, re-activating the take's original app first (e.g.
  /// a take started with Khuluma itself in front, whatever `paste_target` is).
  public func restoringOriginalApp() -> Delivery {
    Delivery(autosend: autosend, sendMode: sendMode, pasteTarget: "restore",
             activateDelayMs: activateDelayMs, sendDelayMs: sendDelayMs)
  }

  /// The same delivery, pasting without pressing the send key.
  public func withoutSending() -> Delivery {
    Delivery(autosend: false, sendMode: sendMode, pasteTarget: pasteTarget,
             activateDelayMs: activateDelayMs, sendDelayMs: sendDelayMs)
  }
}

/// How the daemon answered a warm-up: ready, warming or unavailable.
public struct WarmupReport: Decodable, Equatable, Sendable {
  public enum State: String, Decodable, Sendable {
    /// The daemon holds this model and version.
    case ready
    /// Being built or started elsewhere, or replaced and still cold.
    case warming
    /// Can't be used: see `reason`.
    case unavailable
  }

  public let state: State
  public let reason: String?
  public let message: String?
  public let generation: String?
  public let durationMs: Int?

  public init(state: State, reason: String? = nil, message: String? = nil, generation: String? = nil,
              durationMs: Int? = nil) {
    self.state = state
    self.reason = reason
    self.message = message
    self.generation = generation
    self.durationMs = durationMs
  }

  enum CodingKeys: String, CodingKey {
    case state, reason, message, generation
    case durationMs = "duration_ms"
  }
}
