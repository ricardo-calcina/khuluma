import Foundation

/// The contract between Khuluma and the CLI it was built with. App and CLI
/// ship from one tree, so instead of feature checks Khuluma requires the CLI
/// to speak exactly this version (`app_contract` in `app-config --json`,
/// `TMUX_WHISPER_APP_CONTRACT` in `bin/tmux-whisper`; CI keeps them equal).
public enum AppContract {
  public static let version = 2

  /// The installed CLI speaks a different contract: Khuluma takes no
  /// dictations until the two match.
  public struct Mismatch: Error, LocalizedError, Equatable, Sendable {
    public let cliVersion: String
    /// nil: a CLI from before the contract number existed.
    public let cliContract: Int?

    public var errorDescription: String? {
      let cli = "tmux-whisper \(cliVersion)"
      guard let cliContract else {
        return "\(cli) is older than this Khuluma: run ./install.sh --force"
      }
      if cliContract < AppContract.version {
        return "\(cli) (contract \(cliContract)) is older than this Khuluma (contract \(AppContract.version)): run ./install.sh --force"
      }
      return "this Khuluma (contract \(AppContract.version)) is older than \(cli) (contract \(cliContract)): rebuild it with tools/build-khuluma-app.sh"
    }
  }

  private struct Probe: Decodable {
    let appContract: Int?
    let cliVersion: String?

    enum CodingKeys: String, CodingKey {
      case appContract = "app_contract"
      case cliVersion = "cli_version"
    }
  }

  /// Decodes `app-config --json`, checking the contract before anything
  /// else so an older or newer CLI fails with `Mismatch`, not a decode error.
  public static func decodeAppConfig(_ data: Data) throws -> AppConfig {
    let probe = try JSONDecoder().decode(Probe.self, from: data)
    guard probe.appContract == version else {
      throw Mismatch(cliVersion: probe.cliVersion ?? "?", cliContract: probe.appContract)
    }
    return try JSONDecoder().decode(AppConfig.self, from: data)
  }
}

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
  public let appContract: Int
  public let cliVersion: String
  public let hotkey: String
  public let sounds: [String: Sound]
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

    enum CodingKeys: String, CodingKey {
      case summaryPath = "summary_path"
    }
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
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case appContract = "app_contract"
    case cliVersion = "cli_version"
    case hotkey
    case sounds
    case inline
    case cleanup
    case transcription
    case pipeline
    case config
    case usage
  }

  /// Why Khuluma must not keep the daemon warm, or nil if it may.
  public var supervisionBlocker: String? {
    guard pipeline.supervise else { return "[app] supervise_daemon = false" }
    guard transcription.modelPath?.isEmpty == false else { return "no Parakeet model path" }
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
    if cleanup.requiresCLI { return "CLI locale is not C (\(cleanup.localeCtype ?? "")/\(cleanup.localeCollate ?? ""))" }
    return transcription.cliReason
  }

  /// What the native path needs, or nil when it can't run (see
  /// `nativePipelineBlocker`, and a missing model path).
  public var native: (transcription: TranscriptionSettings, cleanup: CleanupSettings, modelPath: String)? {
    guard nativePipelineBlocker == nil, let modelPath = transcription.modelPath else { return nil }
    return (transcription, cleanup, modelPath)
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
  public let usageDeferred: Bool
  /// The take's history entry is on disk. Missing (a CLI from before the
  /// field) counts as not saved, so a Quit copy of the take is kept.
  public let historySaved: Bool

  enum CodingKeys: String, CodingKey {
    case ok, status, text, mode, message, delivery, timings
    case rawText = "raw_text"
    case usageDeferred = "usage_deferred"
    case historySaved = "history_saved"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ok = try c.decode(Bool.self, forKey: .ok)
    status = try c.decode(String.self, forKey: .status)
    text = try c.decode(String.self, forKey: .text)
    rawText = try c.decode(String.self, forKey: .rawText)
    mode = try c.decodeIfPresent(String.self, forKey: .mode)
    message = try c.decodeIfPresent(String.self, forKey: .message)
    delivery = try c.decode(Delivery.self, forKey: .delivery)
    timings = try c.decode([String: Int].self, forKey: .timings)
    usageDeferred = try c.decode(Bool.self, forKey: .usageDeferred)
    historySaved = try c.decodeIfPresent(Bool.self, forKey: .historySaved) ?? false
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
}

/// `tmux-whisper warmup --json`.
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
