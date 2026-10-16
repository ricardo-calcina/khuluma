import AppKit
import KhulumaCore
import SwiftUI

/// `Lowkey -LowkeyStatsSnapshot <dir>`: renders the stats window from fixed
/// data, in light and dark, to PNGs, then exits. For checking the layout
/// and contrast without screen recording or a real ledger.
@MainActor
enum StatsSnapshot {
  static func write(to directory: String) -> Int32 {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let updated = CivilDate("2026-10-14")!.noon
    var failures = 0
    for (name, model) in fixtures(updated: updated) {
      for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let file = url.appendingPathComponent("stats-\(name)-\(look).png")
        if render(model, appearance: appearance, to: file) {
          print(file.path)
        } else {
          FileHandle.standardError.write(Data("snapshot failed: \(file.lastPathComponent)\n".utf8))
          failures += 1
        }
      }
    }
    return failures == 0 ? 0 : 1
  }

  private static func render(_ model: StatsModel, appearance: NSAppearance.Name, to file: URL) -> Bool {
    let hosting = NSHostingView(rootView: StatsView(model: model, scrolls: false).frame(width: 560))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    window.setContentSize(hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    // Let SwiftUI commit its first frame.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: file)) != nil
  }

  private static func fixtures(updated: Date) -> [(String, StatsModel)] {
    let today = CivilDate("2026-10-14")!
    let full = report(today: today, trackedDays: 75, untracked: 0)
    let fullStats = UsageStats(report: full, today: today, firstWeekday: 2)
    return [
      ("90-days", StatsModel(stats: fullStats, updatedAt: updated, rangeDays: 90, celebrating: 50_000)),
      ("30-days", StatsModel(stats: fullStats, updatedAt: updated, rangeDays: 30)),
      ("incomplete", StatsModel(
        stats: UsageStats(report: report(today: today, trackedDays: 20, untracked: 12), today: today), updatedAt: updated)),
      ("not-started", StatsModel(
        stats: UsageStats(report: report(today: today, trackedDays: 0, untracked: 0, status: "not_started"), today: today),
        updatedAt: updated)),
      ("empty", StatsModel(
        stats: UsageStats(report: UsageReport(trackingStartedAt: nil, dictations: 0, words: 0, recordingMs: 0,
                                              fullElapsedMs: 0, typingWPM: 40, estimatedTimeDifferenceMs: 0,
                                              daily: daily(status: "not_started", today: today, days: [])),
                          today: today),
        updatedAt: updated)),
    ]
  }

  /// A plausible, repeatable history: busier on weekdays, some days off.
  private static func report(today: CivilDate, trackedDays: Int, untracked: Int,
                             status: String? = "active") -> UsageReport {
    var seed: UInt64 = 0x5EED
    func next(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 33) % UInt64(bound))
    }
    var days: [UsageReport.Day] = []
    for offset in stride(from: trackedDays - 1, through: 0, by: -1) {
      let date = today.adding(days: -offset)
      let weekend = date.weekday == 1 || date.weekday == 7
      let roll = next(10)
      // Today has a little; a run of days up to it makes a streak.
      guard offset < 9 || roll >= (weekend ? 6 : 2) else { continue }
      let count = offset == 0 ? 3 : 1 + next(weekend ? 4 : 14)
      let words = count * (40 + next(90))
      let recording = Int(Double(words) / 165 * 60_000)
      days.append(UsageReport.Day(date: date, count: count, words: words, recordingMs: recording,
                                  fullElapsedMs: recording + count * 900,
                                  longestRecordingMs: recording / max(count, 1) * 2, mostWords: words / 2))
    }
    let dictations = days.reduce(0) { $0 + $1.count } + 80 + untracked
    let words = days.reduce(0) { $0 + $1.words } + 24_000
    let recording = days.reduce(0) { $0 + $1.recordingMs } + 8_000_000
    let elapsed = recording + dictations * 900
    let started = UsageReport.parseTimestamp("2026-07-19T06:30:53Z")
    return UsageReport(trackingStartedAt: started, dictations: dictations, words: words, recordingMs: recording,
                       fullElapsedMs: elapsed, typingWPM: 40,
                       estimatedTimeDifferenceMs: words * 60_000 / 40 - elapsed,
                       daily: status.map { daily(status: $0, today: today, days: days, untracked: untracked,
                                                 trackedDays: trackedDays) })
  }

  private static func daily(status: String, today: CivilDate, days: [UsageReport.Day], untracked: Int = 0,
                            trackedDays: Int = 0) -> UsageReport.Daily {
    UsageReport.Daily(status: status, startedAt: status == "active" ? today.adding(days: -(trackedDays - 1)).noon : nil,
                      asOfLocalDate: today, untrackedDeliveries: untracked, days: days)
  }
}
