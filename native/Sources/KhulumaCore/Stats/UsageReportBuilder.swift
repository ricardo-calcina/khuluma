import Foundation

/// `khuluma usage --json --days all`, ported from `usage_summary` in
/// `bin/khuluma-lib/history.sh`: builds the `UsageReport` the Stats window
/// shows straight from `usage.json`. Read without the data lock: the writer
/// replaces the file atomically, so a read sees the old or the new document.
public enum UsageReportBuilder {
  public static let defaultTypingWPM = 40

  public struct Failure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
  }

  /// Largest stored number accepted (2^53, exact in a Double). Anything
  /// bigger is an unsupported file, reported as an error, never a trap.
  public static let limit: Int64 = 1 << 53

  /// A missing file is an empty report (nothing recorded yet); an unreadable
  /// file or another schema is an error.
  public static func report(url: URL, today: CivilDate, typingWPM: Int = defaultTypingWPM) throws -> UsageReport {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return try build(stored: nil, today: today, typingWPM: typingWPM)
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    } catch {
      throw Failure(message: "usage summary is unreadable: \(error.localizedDescription)")
    }
    guard let stored = object as? [String: Any], isOne(stored["schema_version"]),
          stored["delivered_dictations"] is [String: Any] else {
      throw Failure(message: "unsupported usage summary schema")
    }
    return try build(stored: stored, today: today, typingWPM: typingWPM)
  }

  /// `history.typing_wpm` as the CLI reads it: a positive integer, else 40.
  public static func typingWPM(_ configured: Int?) -> Int {
    guard let configured, configured > 0 else { return defaultTypingWPM }
    return configured
  }

  static func build(stored: [String: Any]?, today: CivilDate, typingWPM requested: Int) throws -> UsageReport {
    let wpm = max(1, min(requested, Int(limit)))
    var trackingStartedAt: String?
    var count = 0, words = 0, recordingMs = 0, fullElapsedMs = 0, pauseMs = 0
    if let stored {
      if let started = stored["tracking_started_at"] as? String, !started.isEmpty { trackingStartedAt = started }
      let deliveries = stored["delivered_dictations"] as? [String: Any] ?? [:]
      count = try nonNegative(deliveries["count"])
      words = try nonNegative(stored["processed_words"])
      recordingMs = try nonNegative(stored["recording_duration_ms"])
      fullElapsedMs = try nonNegative(stored["full_elapsed_duration_ms"])
      // Optional: malformed or out of range reads as no measured pauses.
      pauseMs = min(((try? plainInt(stored["pause_duration_ms"])) ?? nil) ?? 0, recordingMs)
    }

    var status = "not_started"
    var startedAt: String?
    var baseline = 0
    var days: [UsageReport.Day] = []
    if let section = stored?["daily"], !(section is NSNull) {
      // All or nothing: one bad value makes the whole section unreadable.
      status = "unreadable"
      if let parsed = try dailyDays(section) {
        status = "active"
        startedAt = (section as? [String: Any])?["started_at"] as? String
        baseline = try plainInt((section as? [String: Any])?["baseline_count"]) ?? 0
        days = parsed
      }
    }

    // Words and wpm are each at most 2^53, so the quotient is below 6e19 / 1:
    // check it fits before converting, then subtract with overflow checks.
    let typingExact = words == 0 ? 0 : (Double(words) * 60000 / Double(wpm)).rounded(.toNearestOrEven)
    guard typingExact < Double(Int64.max) / 2 else { throw outOfRange() }
    let typingEquivalentMs = Int(typingExact)
    var untracked = 0
    if status == "active" {
      var covered = baseline
      for day in days {
        let (sum, overflow) = covered.addingReportingOverflow(day.count)
        if overflow { throw outOfRange() }
        covered = sum
      }
      untracked = max(0, count - covered)  // both are at most ~2^53 * days: no overflow past the check above
    }
    // Measured pauses are left out of the elapsed time too: the typing
    // estimate has no reading pauses either.
    let speakingElapsedMs = max(0, fullElapsedMs - min(pauseMs, fullElapsedMs))
    let (difference, differenceOverflow) = typingEquivalentMs.subtractingReportingOverflow(speakingElapsedMs)
    if differenceOverflow { throw outOfRange() }
    return UsageReport(
      trackingStartedAt: trackingStartedAt.flatMap(UsageReport.parseTimestamp),
      dictations: count, words: words, recordingMs: recordingMs, fullElapsedMs: fullElapsedMs,
      typingWPM: wpm, estimatedTimeDifferenceMs: difference,
      daily: UsageReport.Daily(
        status: status, startedAt: startedAt.flatMap(UsageReport.parseTimestamp), asOfLocalDate: today,
        untrackedDeliveries: untracked, days: days),
      pauseMs: pauseMs)
  }

  private static let timestamp = try! NSRegularExpression(
    pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#)

  /// The validated buckets sorted by date, or nil when anything is malformed.
  private static func dailyDays(_ section: Any) throws -> [UsageReport.Day]? {
    guard let section = section as? [String: Any],
          let buckets = section["days"] as? [String: Any],
          let started = section["started_at"] as? String,
          timestamp.firstMatch(in: started, range: NSRange(started.startIndex..., in: started)) != nil,
          try plainInt(section["baseline_count"]) != nil else { return nil }
    var days: [UsageReport.Day] = []
    for (key, value) in buckets {
      guard let date = CivilDate(key), date.components.year >= 1, let bucket = value as? [String: Any] else { return nil }
      var numbers: [String: Int] = [:]
      for field in ["count", "words", "recording_ms", "full_elapsed_ms", "longest_recording_ms", "most_words",
                    "inline", "tmux"] {
        guard let number = try plainInt(bucket[field]) else { return nil }
        numbers[field] = number
      }
      days.append(UsageReport.Day(
        date: date, count: numbers["count"]!, words: numbers["words"]!, recordingMs: numbers["recording_ms"]!,
        fullElapsedMs: numbers["full_elapsed_ms"]!, longestRecordingMs: numbers["longest_recording_ms"]!,
        mostWords: numbers["most_words"]!,
        pauseMs: ((try? plainInt(bucket["pause_ms"])) ?? nil) ?? 0))
    }
    return days.sorted { $0.date < $1.date }
  }

  /// A JSON integer (not a boolean or a float) that is not negative.
  private static func plainInt(_ value: Any?) throws -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number) else { return nil }
    // Bigger than an Int64 (an unsigned 64-bit value) reads as negative here.
    if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(limit) { throw outOfRange() }
    guard number.int64Value >= 0 else { return nil }
    if number.int64Value > limit { throw outOfRange() }
    return Int(number.int64Value)
  }

  private static func outOfRange() -> Failure {
    Failure(message: "usage summary has a value too large to report")
  }

  private static func isOne(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return number.doubleValue == 1
  }

  /// Python's `int(value)` with a floor of zero: anything unusable is 0.
  private static func nonNegative(_ value: Any?) throws -> Int {
    switch value {
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? 1 : 0 }
      if !CFNumberIsFloatType(number) {
        // Integers are compared exactly, not through a Double.
        if String(cString: number.objCType) == "Q", number.uint64Value > UInt64(limit) { throw outOfRange() }
        let exact = number.int64Value
        if exact > limit { throw outOfRange() }
        return exact < 0 ? 0 : Int(exact)
      }
      let d = number.doubleValue
      guard d.isFinite, d >= 0 else { return 0 }
      if d > Double(limit) { throw outOfRange() }
      return Int(d.rounded(.towardZero))
    case let text as String:
      guard let parsed = Int(text.trimmingCharacters(in: .whitespaces)) else { return 0 }
      if parsed > Int(limit) { throw outOfRange() }
      return max(0, parsed)
    default:
      return 0
    }
  }
}
