import CoreFoundation
import Foundation

/// The transcript-free usage ledger (`usage.json`, schema 1), ported from the
/// CLI's `usage_record_delivery` so existing files import unchanged: totals,
/// per-flow counts, closed daily buckets with `baseline_count`, and
/// `recent_take_ids` (14 days, at most 5000) for exactly-once counting.
/// Unknown keys are preserved. An unreadable file or another schema is never
/// overwritten. The caller holds the data lock.
public struct UsageLedger: Sendable {
  public let url: URL
  public var now: @Sendable () -> Date
  public var timeZone: TimeZone
  public var syncDirectory: DataFiles.SyncDirectory = DataFiles.syncDirectory

  public static let takeIdDays = 14
  public static let takeIdMax = 5000
  public static let dayFields = ["count", "inline", "tmux", "words", "recording_ms", "full_elapsed_ms",
                                 "longest_recording_ms", "most_words"]

  public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
    self.url = url
    self.now = now
    self.timeZone = timeZone
  }

  public struct Delivery: Sendable {
    public var flow: String
    public var text: String
    public var recordMs: Int
    public var fullElapsedMs: Int
    public var takeId: String?
    /// YYYY-MM-DD: the local date at delivery (a replay counts on its day).
    public var localDate: String?
    /// Take ids still waiting in the spool. Never pruned from
    /// `recent_take_ids` (by age or by the cap): one of them may already be
    /// counted with its done flag not yet saved, and its replay must stay a
    /// duplicate.
    public var protectedTakeIds: Set<String>

    public init(flow: String = "inline", text: String, recordMs: Int, fullElapsedMs: Int,
                takeId: String? = nil, localDate: String? = nil, protectedTakeIds: Set<String> = []) {
      self.protectedTakeIds = protectedTakeIds
      self.flow = flow
      self.text = text
      self.recordMs = recordMs
      self.fullElapsedMs = fullElapsedMs
      self.takeId = takeId
      self.localDate = localDate
    }
  }

  public enum Outcome: Equatable, Sendable {
    case recorded(words: Int)
    /// The take id was already counted: nothing changed.
    case duplicate
  }

  /// Non-fatal oddities (the CLI printed them to stderr).
  public typealias Warn = (String) -> Void

  public static func isValidTakeId(_ id: String) -> Bool {
    (1...128).contains(id.utf8.count) && id.unicodeScalars.allSatisfy {
      ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-"
    }
  }

  public func record(_ delivery: Delivery, warn: Warn = { _ in }) throws -> Outcome {
    let flow = delivery.flow
    guard flow == "inline" || flow == "tmux" else { throw DataFiles.Failure("usage: unknown flow \(flow)") }
    guard delivery.recordMs >= 0, delivery.fullElapsedMs >= 0 else { throw DataFiles.Failure("usage: negative duration") }
    let directory = url.deletingLastPathComponent()
    try DataFiles.ensureDirectory(directory)

    let stamp = Self.isoStamp(now())
    var payload: [String: Any]
    var fileOrder: [String] = []
    if FileManager.default.fileExists(atPath: url.path) {
      let object: Any
      do {
        let data = try Data(contentsOf: url)
        fileOrder = Self.takeIdOrder(data)
        object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      } catch {
        throw DataFiles.Failure("usage summary is unreadable; refusing to overwrite it: \(error.localizedDescription)")
      }
      guard let dict = object as? [String: Any] else {
        throw DataFiles.Failure("usage summary is not an object; refusing to overwrite it")
      }
      payload = dict
    } else {
      payload = [
        "schema_version": 1,
        "tracking_started_at": stamp,
        "delivered_dictations": ["count": 0, "by_flow": ["inline": 0, "tmux": 0]] as [String: Any],
        "processed_words": 0,
        "recording_duration_ms": 0,
        "full_elapsed_duration_ms": 0,
      ]
    }

    guard Self.equalsOne(payload["schema_version"]), var deliveries = payload["delivered_dictations"] as? [String: Any] else {
      throw DataFiles.Failure("unsupported usage summary schema; refusing to overwrite it")
    }
    guard var byFlow = deliveries["by_flow"] as? [String: Any] else {
      throw DataFiles.Failure("usage summary is missing flow counts; refusing to overwrite it")
    }

    let today = civilDate(of: now())
    let day = delivery.localDate.flatMap(Self.civilDate) ?? today
    let takeId = delivery.takeId.flatMap { Self.isValidTakeId($0) ? $0 : nil } ?? ""
    var takeIds: [String: Any] = [:]
    switch payload["recent_take_ids"] {
    case nil, is NSNull: break
    case let dict as [String: Any]: takeIds = dict
    default: warn("usage take ids are unreadable; starting them again")
    }
    if !takeId.isEmpty && takeIds[takeId] != nil { return .duplicate }

    let countBefore = try Self.nonNegativeInt(deliveries["count"], "delivered_dictations.count")
    deliveries["count"] = countBefore + 1
    var inline = try Self.nonNegativeInt(byFlow["inline"], "delivered_dictations.by_flow.inline")
    var tmux = try Self.nonNegativeInt(byFlow["tmux"], "delivered_dictations.by_flow.tmux")
    if flow == "inline" { inline += 1 } else { tmux += 1 }
    byFlow["inline"] = inline
    byFlow["tmux"] = tmux
    deliveries["by_flow"] = byFlow
    payload["delivered_dictations"] = deliveries
    let words = WordCount.count(delivery.text)
    let recordMs = delivery.recordMs, elapsedMs = delivery.fullElapsedMs
    payload["processed_words"] = try Self.nonNegativeInt(payload["processed_words"], "processed_words") + words
    payload["recording_duration_ms"] = try Self.nonNegativeInt(payload["recording_duration_ms"], "recording_duration_ms") + recordMs
    payload["full_elapsed_duration_ms"] = try Self.nonNegativeInt(payload["full_elapsed_duration_ms"], "full_elapsed_duration_ms") + elapsedMs

    let dayKey = Self.isoDate(day)
    var dailyValue = payload["daily"]
    if dailyValue == nil || dailyValue is NSNull {
      dailyValue = ["started_at": stamp, "baseline_count": countBefore, "days": [String: Any]()] as [String: Any]
    }
    var recordedDay = false
    if var daily = dailyValue as? [String: Any], Self.plainInt(daily["baseline_count"]) != nil,
       var days = daily["days"] as? [String: Any] {
      let existing = days[dayKey] ?? Dictionary(uniqueKeysWithValues: Self.dayFields.map { ($0, 0 as Any) })
      if let bucketIn = existing as? [String: Any] {
        let values = Self.dayFields.compactMap { Self.plainInt(bucketIn[$0]) }
        if values.count == Self.dayFields.count {
          var bucket = Dictionary(uniqueKeysWithValues: zip(Self.dayFields, values))
          bucket["count"]! += 1
          bucket[flow]! += 1
          bucket["words"]! += words
          bucket["recording_ms"]! += recordMs
          bucket["full_elapsed_ms"]! += elapsedMs
          bucket["longest_recording_ms"] = max(bucket["longest_recording_ms"]!, recordMs)
          bucket["most_words"] = max(bucket["most_words"]!, words)
          days[dayKey] = bucket
          daily["days"] = days
          dailyValue = daily
          recordedDay = true
        }
      }
    }
    payload["daily"] = dailyValue
    if !recordedDay { warn("daily usage is unreadable; recorded the totals only") }

    if !takeId.isEmpty {
      let cutoff = Calendar.gregorian(TimeZone(identifier: "UTC")!).date(byAdding: .day, value: -Self.takeIdDays, to: today)!
      // Python keeps the dict's insertion order (the file's order, then the
      // new id last) and sorts by date only, stably.
      var order = fileOrder.filter { takeIds[$0] != nil }
      let listed = Set(order)
      order += takeIds.keys.filter { !listed.contains($0) }.sorted()
      var kept: [(key: String, date: String)] = []
      for key in order {
        let value = takeIds[key]
        if let text = value as? String, let date = Self.civilDate(text), date > cutoff {
          kept.append((key, text))
        } else if delivery.protectedTakeIds.contains(key) {
          kept.append((key, (value as? String).flatMap { Self.civilDate($0) == nil ? nil : $0 } ?? dayKey))
        }
      }
      kept.append((takeId, dayKey))
      if kept.count > Self.takeIdMax {
        let ranked = kept.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        let protected = ranked.filter { delivery.protectedTakeIds.contains($0.key) || $0.key == takeId }
        let others = ranked.filter { !delivery.protectedTakeIds.contains($0.key) && $0.key != takeId }
        let room = max(Self.takeIdMax - protected.count, 0)
        kept = Array(others.suffix(room)) + protected
      }
      payload["recent_take_ids"] = Dictionary(kept.map { ($0.key, $0.date) }, uniquingKeysWith: { _, last in last })
    }

    var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try DataFiles.replace(url, with: data, syncDirectory: syncDirectory)
    return .recorded(words: words)
  }

  /// The keys of `recent_take_ids` in file order (JSONSerialization drops
  /// it). Take ids are `[A-Za-z0-9._-]`, so the object has no nesting.
  static func takeIdOrder(_ data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    guard let start = text.range(of: "\"recent_take_ids\""),
          let open = text[start.upperBound...].firstIndex(of: "{"),
          let close = text[open...].firstIndex(of: "}") else { return [] }
    let body = String(text[open...close])
    let regex = try! NSRegularExpression(pattern: #""([A-Za-z0-9._-]{1,128})"\s*:"#)
    return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
      Range($0.range(at: 1), in: body).map { String(body[$0]) }
    }
  }

  // MARK: - Python semantics

  private static func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func isFloating(_ number: NSNumber) -> Bool {
    let type = String(cString: number.objCType)
    return type == "d" || type == "f"
  }

  /// `value == 1` in Python (True and 1.0 compare equal too).
  static func equalsOne(_ value: Any?) -> Bool {
    (value as? NSNumber)?.doubleValue == 1
  }

  /// `isinstance(v, int) and not isinstance(v, bool) and v >= 0`.
  static func plainInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !isBool(number), !isFloating(number), number.int64Value >= 0 else { return nil }
    return number.intValue
  }

  /// `as_nonnegative_int`: missing is 0; Python's `int()` takes ints, floats
  /// (truncated) and integer strings; bools, nulls and negatives fail.
  static func nonNegativeInt(_ value: Any?, _ name: String) throws -> Int {
    guard let value else { return 0 }
    var result: Int?
    if let number = value as? NSNumber, !isBool(number) {
      result = isFloating(number) ? (number.doubleValue.isFinite ? Int(number.doubleValue) : nil) : number.intValue
    } else if let text = value as? String {
      result = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let result else { throw DataFiles.Failure("usage summary \(name) must be an integer") }
    guard result >= 0 else { throw DataFiles.Failure("usage summary \(name) must not be negative") }
    return result
  }

  static func isoStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
  }

  /// A valid `YYYY-MM-DD` Gregorian date, as midnight UTC (comparable).
  static func civilDate(_ text: String) -> Date? {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), y >= 1 else { return nil }
    var components = DateComponents(year: y, month: m, day: d)
    components.calendar = Calendar.gregorian(TimeZone(identifier: "UTC")!)
    guard components.isValidDate, let date = components.date else { return nil }
    return date
  }

  /// The local calendar date of `date`, as midnight UTC.
  func civilDate(of date: Date) -> Date {
    let c = Calendar.gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
    return Self.civilDate(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))!
  }

  static func isoDate(_ date: Date) -> String {
    let c = Calendar.gregorian(TimeZone(identifier: "UTC")!).dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}

extension Calendar {
  static func gregorian(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }
}
