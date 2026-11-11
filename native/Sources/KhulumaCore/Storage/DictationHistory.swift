import Foundation

/// Reads the history folder: one JSON record per take, written by
/// HistoryWriter. The `inline-debug` subfolder holds audio and is never
/// read. Newest first.
public enum DictationHistory {
  public struct Item: Identifiable, Equatable, Sendable {
    /// The record's file name.
    public let id: String
    /// The record's `timestamp`; the file's modification time when it
    /// can't be parsed.
    public let date: Date
    /// The app the text went to, "" when the record doesn't say.
    public let app: String
    /// `processed` when non-blank, else `raw`.
    public let text: String
    /// False only when the record says `"delivered": false`.
    public let delivered: Bool
    /// `metrics.record_ms`, when the record has it.
    public let recordMs: Int?

    public init(id: String, date: Date, app: String, text: String,
                delivered: Bool, recordMs: Int?) {
      self.id = id
      self.date = date
      self.app = app
      self.text = text
      self.delivered = delivered
      self.recordMs = recordMs
    }
  }

  public struct Day: Equatable, Sendable {
    public let title: String
    public var items: [Item]
  }

  /// Newest first: date desc, then file name desc (same-second records
  /// order `…_2` before `…`). Only the newest `limit` file names are
  /// parsed, so a long history stays cheap. Skips dot-files, non-regular
  /// files, unreadable or non-object JSON and blank text.
  public static func load(directory: URL, limit: Int = 500) -> [Item] {
    let names = candidateNames(directory, limit: limit)
    let fmt = ISO8601DateFormatter()
    return names.compactMap { name in
      let url = directory.appendingPathComponent(name)
      guard let item = read(url, id: name, format: fmt) else { return nil }
      return item
    }.sorted {
      $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date
    }
  }

  /// The newest readable non-blank item, walking names newest-first.
  public static func latest(directory: URL) -> Item? {
    let fmt = ISO8601DateFormatter()
    for name in candidateNames(directory, limit: .max) {
      if let item = read(directory.appendingPathComponent(name), id: name, format: fmt) {
        return item
      }
    }
    return nil
  }

  /// Every whitespace-separated term must occur in the text or the app,
  /// case- and diacritic-insensitive. A blank query keeps everything.
  public static func filter(_ items: [Item], query: String) -> [Item] {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !terms.isEmpty else { return items }
    return items.filter { item in
      terms.allSatisfy { term in
        item.text.localizedStandardContains(term)
          || item.app.localizedStandardContains(term)
      }
    }
  }

  /// Consecutive same-day runs, newest first: "Today", "Yesterday", else
  /// a short weekday+day ("Mon 9 Nov"). Order is preserved.
  public static func days(_ items: [Item], now: Date, calendar: Calendar,
                          locale: Locale) -> [Day] {
    let fmt = DateFormatter()
    fmt.locale = locale
    fmt.calendar = calendar
    fmt.dateFormat = "EEE d MMM"
    var days: [Day] = []
    for item in items {
      let title: String
      if calendar.isDate(item.date, inSameDayAs: now) {
        title = "Today"
      } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                calendar.isDate(item.date, inSameDayAs: yesterday) {
        title = "Yesterday"
      } else {
        title = fmt.string(from: item.date)
      }
      if days.last?.title == title {
        days[days.count - 1].items.append(item)
      } else {
        days.append(Day(title: title, items: [item]))
      }
    }
    return days
  }

  /// Regular, non-hidden files, newest names first, top `limit` only.
  private static func candidateNames(_ directory: URL, limit: Int) -> [String] {
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    return urls.filter {
      !$0.lastPathComponent.hasPrefix(".")
        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.map(\.lastPathComponent).sorted(by: >).prefix(limit).map { $0 }
  }

  private static func read(_ url: URL, id: String, format fmt: ISO8601DateFormatter) -> Item? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let processed = (object["processed"] as? String) ?? ""
    let raw = (object["raw"] as? String) ?? ""
    let text = processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? raw : processed
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var date = (object["timestamp"] as? String).flatMap { fmt.date(from: $0) }
    if date == nil {
      date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    guard let date else { return nil }
    let delivered = (object["delivered"] as? Bool) ?? true
    let metrics = object["metrics"] as? [String: Any]
    return Item(id: id, date: date, app: object["app"] as? String ?? "",
                text: text, delivered: delivered,
                recordMs: metrics?["record_ms"] as? Int)
  }
}
