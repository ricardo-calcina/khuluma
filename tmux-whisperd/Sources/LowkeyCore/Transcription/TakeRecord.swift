import Foundation

/// Payload for `tmux-whisper inline record --json`: one native take's
/// outcome, persisted by the CLI's own history/bench/usage writers.
public struct TakeRecord: Codable, Equatable, Sendable {
  public var takeId: String
  /// ok | no_speech | transcribe_failed | paste_failed (bench status).
  public var status: String
  /// The text reached the target app. Usage is counted only then.
  public var delivered: Bool
  public var rawText: String = ""
  public var text: String = ""
  public var mode: String?
  public var app: String?
  /// Model label at the time of the take (bench `model`).
  public var model: String?
  public var recordMs: Int = 0
  public var transcribeMs: Int = 0
  public var cleanMs: Int = 0
  public var pasteMs: Int = 0
  public var totalMs: Int = 0
  public var startupMs: Int = 0
  public var startedAtMs: Int?
  public var deliveredAtMs: Int?
  public var captureWavMs: Int?
  public var captureWavBytes: Int?
  public var startupSource: String = "app:native"
  /// Padded WAV for the `[debug] keep_logs` archive; `inline record` takes
  /// ownership and removes it.
  public var wavPath: String?

  public init(takeId: String, status: String, delivered: Bool) {
    self.takeId = takeId
    self.status = status
    self.delivered = delivered
  }

  enum CodingKeys: String, CodingKey {
    case takeId = "take_id"
    case status, delivered, text, mode, app, model
    case rawText = "raw_text"
    case recordMs = "record_ms"
    case transcribeMs = "transcribe_ms"
    case cleanMs = "clean_ms"
    case pasteMs = "paste_ms"
    case totalMs = "total_ms"
    case startupMs = "startup_ms"
    case startedAtMs = "started_at_ms"
    case deliveredAtMs = "delivered_at_ms"
    case captureWavMs = "capture_wav_ms"
    case captureWavBytes = "capture_wav_bytes"
    case startupSource = "startup_source"
    case wavPath = "wav_path"
  }
}

/// `inline record --json`'s answer.
public struct RecordResult: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let takeId: String
  public let usageRecorded: Bool
  public let historySaved: Bool

  enum CodingKeys: String, CodingKey {
    case ok
    case takeId = "take_id"
    case usageRecorded = "usage_recorded"
    case historySaved = "history_saved"
  }
}
