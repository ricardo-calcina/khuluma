import Foundation

/// One finished take's outcome, spooled in `PendingRecords` and written to
/// history and usage by `TakeRecorder`. The JSON keys are the ones build 415
/// spooled for the CLI, so its leftovers still decode.
public struct TakeRecord: Codable, Equatable, Sendable {
  public var takeId: String
  /// ok | no_speech | transcribe_failed | paste_failed (bench status).
  public var status: String
  /// The text reached the target app. Usage is counted only then.
  public var delivered: Bool
  public var rawText: String = ""
  public var text: String = ""
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
  /// The local date (Gregorian, YYYY-MM-DD) when the text was delivered, so
  /// a take replayed on a later day still counts toward its own day.
  public var deliveredLocalDate: String?
  /// Records only the usage of a take `inline process --defer-usage`
  /// already saved to history and bench.
  public var usageOnly: Bool?
  /// Padded WAV for the `[debug] keep_logs` archive; `TakeRecorder` takes
  /// ownership and removes it once the take is saved.
  public var wavPath: String?

  public init(takeId: String, status: String, delivered: Bool) {
    self.takeId = takeId
    self.status = status
    self.delivered = delivered
  }

  enum CodingKeys: String, CodingKey {
    case takeId = "take_id"
    case status, delivered, text, app, model
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
    case deliveredLocalDate = "delivered_local_date"
    case usageOnly = "usage_only"
  }
}
