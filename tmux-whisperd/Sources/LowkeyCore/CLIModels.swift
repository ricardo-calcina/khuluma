import Foundation

/// `tmux-whisper app-config --json`
public struct AppConfig: Decodable, Equatable, Sendable {
  public struct Sound: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let path: String?
  }

  public struct Inline: Decodable, Equatable, Sendable {
    public let autosend: Bool
    public let sendMode: String
    public let pasteTarget: String
    public let processSound: Bool
    public let activateDelayMs: Int
    public let sendDelayMs: Int

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
  public let cliVersion: String
  public let hotkey: String
  public let sounds: [String: Sound]
  public let inline: Inline
  /// Text cleanup settings for the native TextPipeline. Absent from CLIs
  /// older than 0.10.
  public let cleanup: CleanupSettings?
  /// Transcription settings for the native path (0.10+).
  public let transcription: TranscriptionSettings?
  /// `[app] native_pipeline` / `verify_pipeline` (0.10+).
  public let pipeline: Pipeline?
  /// Whether config.toml parsed (0.10+).
  public let config: ConfigStatus?
  /// What the CLI supports (0.11+), e.g. "take_markers", "lifecycle_lock",
  /// "warmup_json", "usage_days", "deferred_usage".
  public let capabilities: [String]?
  /// Where the usage ledger lives (0.11+).
  public let usage: Usage?

  public struct Usage: Decodable, Equatable, Sendable {
    public let summaryPath: String

    enum CodingKeys: String, CodingKey {
      case summaryPath = "summary_path"
    }
  }

  public func supports(_ capability: String) -> Bool {
    capabilities?.contains(capability) ?? false
  }

  public struct ConfigStatus: Decodable, Equatable, Sendable {
    /// The TOML parse error, if config.toml is invalid.
    public let error: String?
    /// "file", or when invalid: "last_good" (last valid copy) or "defaults".
    public let source: String
  }

  /// config.toml is invalid and there was no valid copy to fall back to, so
  /// the settings are the built-in defaults rather than the user's.
  public var usingFallbackDefaults: Bool {
    guard let config, config.error != nil else { return false }
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
    public let native: Bool
    public let verify: Bool
    /// `[app] supervise_daemon` (0.11+; absent from older CLIs).
    public let supervise: Bool?
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case cliVersion = "cli_version"
    case hotkey
    case sounds
    case inline
    case cleanup
    case transcription
    case pipeline
    case config
    case capabilities
    case usage
  }

  /// CLI features daemon supervision relies on: markers that keep upgrades
  /// out of a take, serialized daemon starts, and a truthful warmup.
  public static let supervisionCapabilities = ["take_markers", "lifecycle_lock", "warmup_json"]

  /// Why Lowkey must not keep the daemon warm, or nil if it may. An older
  /// CLI keeps 3b behaviour: the daemon is started only by CLI fallbacks.
  public var supervisionBlocker: String? {
    let have = Set(capabilities ?? [])
    guard Self.supervisionCapabilities.allSatisfy(have.contains) else { return "CLI too old for daemon supervision" }
    guard pipeline?.supervise ?? false else { return "[app] supervise_daemon = false" }
    guard transcription?.modelPath?.isEmpty == false else { return "no Parakeet model path" }
    return nil
  }

  /// The delivery settings as `inline process` reports them (made safe when
  /// config.toml is invalid with no last valid copy).
  public var delivery: Delivery {
    safeDelivery(Delivery(autosend: inline.autosend, sendMode: inline.sendMode, pasteTarget: inline.pasteTarget,
                          activateDelayMs: inline.activateDelayMs, sendDelayMs: inline.sendDelayMs))
  }

  /// Why a take must go through `inline process` instead of the native
  /// pipeline, or nil if the native path reproduces the CLI.
  public var nativePipelineBlocker: String? {
    guard pipeline?.native ?? false else { return pipeline == nil ? "CLI too old for the native path" : "[app] native_pipeline = false" }
    guard let cleanup else { return "no cleanup settings" }
    if cleanup.postprocess { return "LLM post-processing is on" }
    if cleanup.requiresCLI { return "CLI locale is not C (\(cleanup.localeCtype ?? "")/\(cleanup.localeCollate ?? ""))" }
    guard let transcription else { return "no transcription settings" }
    return transcription.cliReason
  }
}

/// `tmux-whisper inline cleanup --app NAME --json` (transcript on stdin).
public struct CleanupResult: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let status: String
  public let rawText: String
  public let text: String
  public let mode: String?
  public let cleanup: CleanupSettings

  enum CodingKeys: String, CodingKey {
    case ok, status, text, mode, cleanup
    case rawText = "raw_text"
  }
}

/// `tmux-whisper inline process <wav> --json`
public struct ProcessResult: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let status: String
  public let text: String
  public let rawText: String
  public let mode: String?
  public let message: String?
  public let delivery: Delivery
  public let timings: [String: Int]
  /// `--defer-usage` was honoured: the caller records usage after delivery.
  public let usageDeferred: Bool?

  enum CodingKeys: String, CodingKey {
    case ok, status, text, mode, message, delivery, timings
    case rawText = "raw_text"
    case usageDeferred = "usage_deferred"
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
  /// a take started with Lowkey itself in front, whatever `paste_target` is).
  public func restoringOriginalApp() -> Delivery {
    Delivery(autosend: autosend, sendMode: sendMode, pasteTarget: "restore",
             activateDelayMs: activateDelayMs, sendDelayMs: sendDelayMs)
  }
}

/// `tmux-whisper warmup --json` (0.11+).
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
