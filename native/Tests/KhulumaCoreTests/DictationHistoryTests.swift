import Foundation
import Testing
@testable import KhulumaCore

/// DictationHistory reads the history folder: ordering, fallbacks,
/// skipping, filtering and day grouping.
struct DictationHistoryTests {
  private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func write(_ dir: URL, _ name: String, _ json: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: json)
    try data.write(to: dir.appendingPathComponent(name))
  }

  @Test func newestFirstByDateThenName() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir, "2026-11-09T10-00-00.json", ["timestamp": "2026-11-09T10:00:00Z", "raw": "first"])
    // Same second, lexically-later suffix wins the tie.
    try write(dir, "2026-11-09T10-00-00_2.json", ["timestamp": "2026-11-09T10:00:00Z", "raw": "second"])
    try write(dir, "2026-11-10T09-00-00.json", ["timestamp": "2026-11-10T09:00:00Z", "raw": "newest"])
    let items = DictationHistory.load(directory: dir)
    #expect(items.map(\.text) == ["newest", "second", "first"])
  }

  @Test func processedWinsOverRawAndBlankProcessedFallsBack() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir, "2026-11-09T10-00-00.json",
              ["timestamp": "2026-11-09T10:00:00Z", "raw": "spoken", "processed": "cleaned"])
    try write(dir, "2026-11-09T11-00-00.json",
              ["timestamp": "2026-11-09T11:00:00Z", "raw": "spoken only", "processed": " "])
    let items = DictationHistory.load(directory: dir)
    #expect(items.map(\.text) == ["spoken only", "cleaned"])
  }

  @Test func skipsJunkAndBlankEntries() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data([1]).write(to: dir.appendingPathComponent(".hidden.json"))
    try Data("not json".utf8).write(to: dir.appendingPathComponent("2026-11-09T10-00-00.json"))
    try write(dir, "2026-11-09T11-00-00.json", ["timestamp": "2026-11-09T11:00:00Z", "raw": " "])
    try write(dir, "2026-11-09T12-00-00.json", ["not" : "an object shape but a dict", "raw": ""])
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("inline-debug", isDirectory: true), withIntermediateDirectories: true)
    try write(dir, "2026-11-09T13-00-00.json",
              ["timestamp": "2026-11-09T13:00:00Z", "raw": "kept", "delivered": false,
               "metrics": ["record_ms": 1234]])
    let items = DictationHistory.load(directory: dir)
    #expect(items.count == 1)
    #expect(items[0].delivered == false)
    #expect(items[0].recordMs == 1234)
  }

  @Test func limitReadsOnlyTheNewestNames() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0..<6 {
      try write(dir, "2026-11-0\(i)T10-00-00.json", ["timestamp": "2026-11-0\(i)T10:00:00Z", "raw": "take \(i)"])
    }
    #expect(DictationHistory.load(directory: dir, limit: 2).map(\.text) == ["take 5", "take 4"])
  }

  @Test func latestSkipsABlankNewest() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir, "2026-11-10T10-00-00.json", ["timestamp": "2026-11-10T10:00:00Z", "raw": "  "])
    try write(dir, "2026-11-09T10-00-00.json", ["timestamp": "2026-11-09T10:00:00Z", "raw": "the take"])
    #expect(DictationHistory.latest(directory: dir)?.text == "the take")
  }

  @Test func filterNeedsEveryTermCaseAndDiacriticFree() throws {
    let items = [
      DictationHistory.Item(id: "a", date: Date(), app: "Messages", text: "Café morning", delivered: true, recordMs: nil),
      DictationHistory.Item(id: "b", date: Date(), app: "Notes", text: "cafe lunch", delivered: true, recordMs: nil),
      DictationHistory.Item(id: "c", date: Date(), app: "Safari", text: "morning walk", delivered: true, recordMs: nil),
    ]
    #expect(DictationHistory.filter(items, query: "").count == 3)
    #expect(DictationHistory.filter(items, query: "CAFE").map(\.id) == ["a", "b"])
    #expect(DictationHistory.filter(items, query: "café").map(\.id) == ["a", "b"])
    #expect(DictationHistory.filter(items, query: "morning messages").map(\.id) == ["a"])
    #expect(DictationHistory.filter(items, query: "safari walk").map(\.id) == ["c"])
    #expect(DictationHistory.filter(items, query: "cafe notes").map(\.id) == ["b"])
  }

  @Test func daysGroupAcrossMidnightInTheGivenCalendar() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
    func item(_ name: String, _ day: Int, _ hour: Int) -> DictationHistory.Item {
      let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
      return .init(id: name, date: date, app: "", text: name, delivered: true, recordMs: nil)
    }
    let items = [item("late today", 10, 23), item("early today", 10, 1),
                 item("yesterday", 9, 12), item("older", 7, 9)]
    let days = DictationHistory.days(items, now: now, calendar: calendar,
                                     locale: Locale(identifier: "en_GB"))
    #expect(days.map(\.title) == ["Today", "Yesterday", "Sat 7 Nov"])
    #expect(days[0].items.map(\.id) == ["late today", "early today"])
  }
}
