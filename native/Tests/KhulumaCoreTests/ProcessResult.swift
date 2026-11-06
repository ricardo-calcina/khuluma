import Foundation
@testable import KhulumaCore

// Test-only: the CLI's `inline process` result, read by the dev parity tests
// (LiveParityTests, ShadowCompare). The app no longer runs the CLI.
/// `khuluma inline process <wav> --json`
struct ProcessResult: Decodable, Equatable, Sendable {
  let ok: Bool
  let status: String
  let text: String
  let rawText: String
  let message: String?
  let delivery: Delivery
  let timings: [String: Int]
  /// `--defer-usage` was honoured: the caller records usage after delivery.
  let usageDeferred: Bool
  /// The take's history entry is on disk. Missing (a CLI from before the
  /// field) counts as not saved, so a Quit copy of the take is kept.
  let historySaved: Bool

  enum CodingKeys: String, CodingKey {
    case ok, status, text, message, delivery, timings
    case rawText = "raw_text"
    case usageDeferred = "usage_deferred"
    case historySaved = "history_saved"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ok = try c.decode(Bool.self, forKey: .ok)
    status = try c.decode(String.self, forKey: .status)
    text = try c.decode(String.self, forKey: .text)
    rawText = try c.decode(String.self, forKey: .rawText)
    message = try c.decodeIfPresent(String.self, forKey: .message)
    delivery = try c.decode(Delivery.self, forKey: .delivery)
    timings = try c.decode([String: Int].self, forKey: .timings)
    usageDeferred = try c.decode(Bool.self, forKey: .usageDeferred)
    historySaved = try c.decodeIfPresent(Bool.self, forKey: .historySaved) ?? false
  }
}

