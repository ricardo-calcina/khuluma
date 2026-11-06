import Foundation

/// The transcription settings takes use (built from settings.json). Numeric
/// values stay raw strings, parsed with the rules the CLI used, so behaviour
/// is unchanged from the CLI era.
public struct TranscriptionSettings: Codable, Equatable, Sendable {
  /// The explicit transcription destination; cloud is always opt-in.
  public var provider: String
  /// Presence only. Credentials never cross app-config or enter logs.
  public var keyAvailable: Bool
  public var socketPath: String
  public var modelPath: String?
  public var modelVersion: String?
  public var modelLabel: String
  public var language: String
  /// `KHULUMA_TRANSCRIBE_TAIL_PAD_MS` (default "500").
  public var tailPadMs: String
  public var tailRescue: Bool
  /// `KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE_MS` ("" = 8000).
  public var tailRescueMs: String
  /// `KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE_MIN_MS` ("" = 12000).
  public var tailRescueMinMs: String
  public var keepLogs: Bool
  /// ffmpeg and ffprobe exist (the CLI skips padding and rescue otherwise).
  public var ffmpeg: Bool
  public var timeoutSeconds: String
  public var processingDir: String

  public init(
    socketPath: String, modelPath: String?, modelVersion: String? = "v3", modelLabel: String = "parakeet",
    language: String = "en", tailPadMs: String = "500", tailRescue: Bool = true, tailRescueMs: String = "",
    tailRescueMinMs: String = "", keepLogs: Bool = false,
    ffmpeg: Bool = true, timeoutSeconds: String = "600", processingDir: String = TakeMarker.defaultDirectory,
    provider: String = "parakeet", keyAvailable: Bool = false
  ) {
    self.provider = provider
    self.keyAvailable = keyAvailable
    self.socketPath = socketPath
    self.modelPath = modelPath
    self.modelVersion = modelVersion
    self.modelLabel = modelLabel
    self.language = language
    self.tailPadMs = tailPadMs
    self.tailRescue = tailRescue
    self.tailRescueMs = tailRescueMs
    self.tailRescueMinMs = tailRescueMinMs
    self.keepLogs = keepLogs
    self.ffmpeg = ffmpeg
    self.timeoutSeconds = timeoutSeconds
    self.processingDir = processingDir
  }

  enum CodingKeys: String, CodingKey {
    case provider
    case keyAvailable = "key_available"
    case socketPath = "socket_path"
    case modelPath = "model_path"
    case modelVersion = "model_version"
    case modelLabel = "model_label"
    case language
    case tailPadMs = "tail_pad_ms"
    case tailRescue = "tail_rescue"
    case tailRescueMs = "tail_rescue_ms"
    case tailRescueMinMs = "tail_rescue_min_ms"
    case keepLogs = "keep_logs"
    case ffmpeg
    case timeoutSeconds = "timeout_seconds"
    case processingDir = "processing_dir"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "parakeet"
    keyAvailable = try values.decodeIfPresent(Bool.self, forKey: .keyAvailable) ?? false
    socketPath = try values.decode(String.self, forKey: .socketPath)
    modelPath = try values.decodeIfPresent(String.self, forKey: .modelPath)
    modelVersion = try values.decodeIfPresent(String.self, forKey: .modelVersion)
    modelLabel = try values.decode(String.self, forKey: .modelLabel)
    language = try values.decode(String.self, forKey: .language)
    tailPadMs = try values.decode(String.self, forKey: .tailPadMs)
    tailRescue = try values.decode(Bool.self, forKey: .tailRescue)
    tailRescueMs = try values.decode(String.self, forKey: .tailRescueMs)
    tailRescueMinMs = try values.decode(String.self, forKey: .tailRescueMinMs)
    keepLogs = try values.decode(Bool.self, forKey: .keepLogs)
    ffmpeg = try values.decode(Bool.self, forKey: .ffmpeg)
    timeoutSeconds = try values.decode(String.self, forKey: .timeoutSeconds)
    processingDir = try values.decode(String.self, forKey: .processingDir)
  }

  /// Why takes can't be transcribed with this configuration yet (they are
  /// kept until they can), or nil if they can.
  public var blocker: String? {
    // Scribe runs natively (`AppConfig.scribe`); it needs no local model.
    if provider == "elevenlabs" { return nil }
    if provider != "parakeet" { return "unsupported transcription provider" }
    if modelPath?.isEmpty ?? true { return Self.modelMissing }
    return nil
  }

  /// No usable model yet: the app downloads it on first run.
  public static let modelMissing = "speech model still downloading"

  /// Silence appended before ASR, in ms (0 = none).
  public var tailPad: Int? { Self.bashInt(tailPadMs.isEmpty ? "500" : tailPadMs, default: 500).map { max(0, $0) } }
  var rescueMs: Int? { Self.bashInt(tailRescueMs, default: 8000) }
  var rescueMinMs: Int? { Self.bashInt(tailRescueMinMs, default: 12000) }

  /// The daemon socket timeout the CLI would use (`float()` of the env var).
  public var maxTimeout: Double {
    let value = Double(timeoutSeconds.trimmingCharacters(in: .whitespaces)) ?? 600
    return value.isFinite && value > 0 ? value : 600
  }

  /// `[[ "$v" =~ ^[0-9]+$ ]] || v=default`, then bash arithmetic. nil when
  /// bash would parse the digits differently (leading zero → octal) or they
  /// overflow.
  static func bashInt(_ raw: String, default fallback: Int) -> Int? {
    let isDigits = !raw.isEmpty && raw.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    guard isDigits else { return fallback }
    // Leading zeros read as decimal now (no bash to read them as octal);
    // an overflow uses the default.
    return Int(raw) ?? fallback
  }
}
