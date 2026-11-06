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
  /// Time spent speaking (word timings, pauses over 1 s left out), at most
  /// `recordMs`; nil when unknown (older records, no timings).
  public var speechMs: Int? {
    get { speechMsField.value }
    set { speechMsField = TolerantInt(newValue) }
  }
  private var speechMsField = TolerantInt(nil)
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
    case speechMsField = "speech_ms"
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

/// An optional metric that never fails decoding: anything that isn't a
/// non-negative integer reads as nil, so a bad value can't cost a take.
struct TolerantInt: Codable, Equatable, Sendable {
  var value: Int?

  init(_ value: Int?) { self.value = value }

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    value = (try? c.decode(Int.self)).flatMap { $0 >= 0 ? $0 : nil }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    if let value { try c.encode(value) } else { try c.encodeNil() }
  }
}

extension KeyedEncodingContainer {
  /// Omits the key when the metric is unknown, as an Optional would.
  mutating func encode(_ value: TolerantInt, forKey key: Key) throws {
    if let v = value.value { try encode(v, forKey: key) }
  }
}

extension KeyedDecodingContainer {
  /// A missing key is nil too.
  func decode(_ type: TolerantInt.Type, forKey key: Key) throws -> TolerantInt {
    (try? decodeIfPresent(TolerantInt.self, forKey: key)).flatMap { $0 } ?? TolerantInt(nil)
  }
}
