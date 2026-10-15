import Foundation

/// `tmux-whisper usage --json [--days N|all]`: transcript-free totals and,
/// with `--days`, per-day buckets. Only numbers and dates are decoded; any
/// negative count or malformed date rejects the whole report.
public struct UsageReport: Decodable, Equatable, Sendable {
  public struct Day: Decodable, Equatable, Sendable {
    public let date: CivilDate
    public let count: Int
    public let words: Int
    public let recordingMs: Int
    public let fullElapsedMs: Int
    public let longestRecordingMs: Int
    public let mostWords: Int

    public init(date: CivilDate, count: Int, words: Int, recordingMs: Int, fullElapsedMs: Int = 0,
                longestRecordingMs: Int = 0, mostWords: Int = 0) {
      self.date = date
      self.count = count
      self.words = words
      self.recordingMs = recordingMs
      self.fullElapsedMs = fullElapsedMs
      self.longestRecordingMs = longestRecordingMs
      self.mostWords = mostWords
    }

    enum CodingKeys: String, CodingKey {
      case date, count, words
      case recordingMs = "recording_ms"
      case fullElapsedMs = "full_elapsed_ms"
      case longestRecordingMs = "longest_recording_ms"
      case mostWords = "most_words"
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      guard let date = CivilDate(try c.decode(String.self, forKey: .date)) else {
        throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "not a YYYY-MM-DD date")
      }
      self.date = date
      count = try c.decodeCount(.count)
      words = try c.decodeCount(.words)
      recordingMs = try c.decodeCount(.recordingMs)
      fullElapsedMs = try c.decodeCount(.fullElapsedMs)
      longestRecordingMs = try c.decodeCount(.longestRecordingMs)
      mostWords = try c.decodeCount(.mostWords)
    }
  }

  public struct Daily: Decodable, Equatable, Sendable {
    /// active | not_started | unreadable
    public let status: String
    public let startedAt: Date?
    /// The CLI's "today", so both sides agree on the day.
    public let asOfLocalDate: CivilDate?
    /// Deliveries recorded without a day (e.g. by an older CLI).
    public let untrackedDeliveries: Int
    public let days: [Day]

    public init(status: String, startedAt: Date?, asOfLocalDate: CivilDate?, untrackedDeliveries: Int, days: [Day]) {
      self.status = status
      self.startedAt = startedAt
      self.asOfLocalDate = asOfLocalDate
      self.untrackedDeliveries = untrackedDeliveries
      self.days = days
    }

    enum CodingKeys: String, CodingKey {
      case status, days
      case startedAt = "started_at"
      case asOfLocalDate = "as_of_local_date"
      case untrackedDeliveries = "untracked_deliveries"
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      status = try c.decode(String.self, forKey: .status)
      startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt).flatMap(UsageReport.parseTimestamp)
      asOfLocalDate = try c.decodeIfPresent(String.self, forKey: .asOfLocalDate).flatMap(CivilDate.init)
      untrackedDeliveries = try c.decodeCount(.untrackedDeliveries)
      days = try c.decode([Day].self, forKey: .days)
    }
  }

  public let trackingStartedAt: Date?
  public let dictations: Int
  public let words: Int
  public let recordingMs: Int
  public let fullElapsedMs: Int
  public let typingWPM: Int
  /// typing-equivalent minus record start → delivered (an estimate).
  public let estimatedTimeDifferenceMs: Int
  /// Present when asked with `--days` (Lowkey always asks for `all`).
  public let daily: Daily?

  public init(trackingStartedAt: Date?, dictations: Int, words: Int, recordingMs: Int, fullElapsedMs: Int,
              typingWPM: Int, estimatedTimeDifferenceMs: Int, daily: Daily?) {
    self.trackingStartedAt = trackingStartedAt
    self.dictations = dictations
    self.words = words
    self.recordingMs = recordingMs
    self.fullElapsedMs = fullElapsedMs
    self.typingWPM = typingWPM
    self.estimatedTimeDifferenceMs = estimatedTimeDifferenceMs
    self.daily = daily
  }

  enum CodingKeys: String, CodingKey {
    case command, coverage, daily
    case schemaVersion = "schema_version"
    case deliveredDictations = "delivered_dictations"
    case processedWords = "processed_words"
    case recordingDurationMs = "recording_duration_ms"
    case fullElapsedDurationMs = "full_elapsed_duration_ms"
    case typingAssumption = "typing_assumption"
    case estimatedTimeDifferenceMs = "estimated_time_difference_ms"
  }

  private enum CoverageKeys: String, CodingKey {
    case trackingStartedAt = "tracking_started_at"
  }

  private enum DeliveryKeys: String, CodingKey {
    case count
  }

  private enum TypingKeys: String, CodingKey {
    case wpm
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(String.self, forKey: .command) == "usage", try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
      throw DecodingError.dataCorruptedError(forKey: .command, in: c, debugDescription: "not a usage v1 report")
    }
    let coverage = try c.nestedContainer(keyedBy: CoverageKeys.self, forKey: .coverage)
    trackingStartedAt = try coverage.decodeIfPresent(String.self, forKey: .trackingStartedAt).flatMap(Self.parseTimestamp)
    dictations = try c.nestedContainer(keyedBy: DeliveryKeys.self, forKey: .deliveredDictations).decodeCount(.count)
    words = try c.decodeCount(.processedWords)
    recordingMs = try c.decodeCount(.recordingDurationMs)
    fullElapsedMs = try c.decodeCount(.fullElapsedDurationMs)
    typingWPM = max(1, try c.nestedContainer(keyedBy: TypingKeys.self, forKey: .typingAssumption).decodeCount(.wpm))
    estimatedTimeDifferenceMs = try c.decode(Int.self, forKey: .estimatedTimeDifferenceMs)
    daily = try c.decodeIfPresent(Daily.self, forKey: .daily)
  }

  public static func parseTimestamp(_ value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
  }
}

private extension KeyedDecodingContainer {
  func decodeCount(_ key: Key) throws -> Int {
    let value = try decode(Int.self, forKey: key)
    guard value >= 0 else {
      throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "negative count")
    }
    return value
  }
}

/// A calendar date with no time or zone (the CLI's YYYY-MM-DD day keys),
/// as a day number so arithmetic never meets DST or the user's calendar.
public struct CivilDate: Hashable, Comparable, Sendable, CustomStringConvertible {
  /// Days since 1970-01-01.
  public let dayNumber: Int

  public init(dayNumber: Int) {
    self.dayNumber = dayNumber
  }

  public init?(year: Int, month: Int, day: Int) {
    guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year) else { return nil }
    // Howard Hinnant's days_from_civil.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    dayNumber = era * 146_097 + doe - 719_468
  }

  public init?(_ string: String) {
    let parts = string.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
    self.init(year: year, month: month, day: day)
  }

  /// The local (Gregorian) date of `date` in `timeZone`.
  public init(_ date: Date, timeZone: TimeZone = .current) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    self = CivilDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1) ?? CivilDate(dayNumber: 0)
  }

  public var components: (year: Int, month: Int, day: Int) {
    // Howard Hinnant's civil_from_days.
    let z = dayNumber + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }

  /// 1 = Sunday … 7 = Saturday, as `Calendar.firstWeekday` counts.
  public var weekday: Int {
    // 1970-01-01 was a Thursday (5).
    ((dayNumber % 7 + 7) % 7 + 4) % 7 + 1
  }

  public func adding(days: Int) -> CivilDate {
    CivilDate(dayNumber: dayNumber + days)
  }

  public var description: String {
    let c = components
    return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
  }

  public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
    lhs.dayNumber < rhs.dayNumber
  }

  private static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }
}
