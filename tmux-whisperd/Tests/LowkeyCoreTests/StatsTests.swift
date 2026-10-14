import Foundation
import Testing
@testable import LowkeyCore

private func date(_ s: String) -> CivilDate { CivilDate(s)! }

private func day(_ s: String, count: Int, words: Int = 100, recordingMs: Int = 30_000, longest: Int = 10_000) -> UsageReport.Day {
  UsageReport.Day(date: date(s), count: count, words: words, recordingMs: recordingMs, longestRecordingMs: longest,
                  mostWords: words)
}

private func report(days: [UsageReport.Day], today: String, started: String = "2026-10-01T06:00:00Z",
                    untracked: Int = 0, words: Int = 24_306) -> UsageReport {
  UsageReport(trackingStartedAt: UsageReport.parseTimestamp("2026-09-19T06:30:53Z"), dictations: 80, words: words,
              recordingMs: 8_112_000, fullElapsedMs: 8_484_000, typingWPM: 40, estimatedTimeDifferenceMs: 27_975_000,
              daily: UsageReport.Daily(status: "active", startedAt: UsageReport.parseTimestamp(started),
                                       asOfLocalDate: date(today), untrackedDeliveries: untracked, days: days))
}

private let utc = TimeZone(identifier: "UTC")!

struct CivilDateTests {
  @Test func roundTripsAndKnowsItsWeekday() {
    #expect(date("1970-01-01").dayNumber == 0)
    #expect(date("2026-10-14").description == "2026-10-14")
    #expect(date("2026-10-14").weekday == 4) // Wednesday
    #expect(date("2026-10-18").weekday == 1) // Sunday
    #expect(date("2024-02-28").adding(days: 1).description == "2024-02-29")
    #expect(date("2026-12-31").adding(days: 1).description == "2027-01-01")
    #expect(CivilDate("2026-02-29") == nil && CivilDate("2026-1-05") == nil && CivilDate("26-10-14") == nil)
    #expect(CivilDate("２０２６-10-14") == nil)
  }

  @Test func dateKeysIgnoreTheUsersCalendarAndDST() throws {
    // The clocks go back in London on 25 Oct 2026: still one day apart.
    #expect(date("2026-10-26").dayNumber - date("2026-10-25").dayNumber == 1)
    let london = try #require(TimeZone(identifier: "Europe/London"))
    let lateOnTheChange = try #require(UsageReport.parseTimestamp("2026-10-25T23:30:00Z"))
    #expect(CivilDate(lateOnTheChange, timeZone: london).description == "2026-10-25")
  }
}

struct UsageReportTests {
  let new = #"""
  {"command":"usage","schema_version":1,
   "coverage":{"status":"active","tracking_started_at":"2026-09-19T06:30:53Z","daily_tracking_started_at":"2026-10-14T21:30:00Z","scope":"x"},
   "delivered_dictations":{"count":82,"by_flow":{"inline":82,"tmux":0}},"processed_words":24311,
   "recording_duration_ms":8116000,"full_elapsed_duration_ms":8488700,
   "typing_assumption":{"wpm":40,"typing_equivalent_duration_ms":36466500},"estimated_time_difference_ms":27977800,
   "daily":{"status":"active","started_at":"2026-10-14T21:30:00Z","as_of_local_date":"2026-10-15",
     "range":{"from":"2026-10-15","to":"2026-10-15"},"untracked_deliveries":0,
     "days":[{"date":"2026-10-15","count":2,"words":5,"recording_ms":4000,"full_elapsed_ms":4700,
              "longest_recording_ms":3000,"most_words":3,"by_flow":{"inline":2,"tmux":0},"note":"ignored"}]}}
  """#

  @Test func decodesTheDailyReport() throws {
    let r = try JSONDecoder().decode(UsageReport.self, from: Data(new.utf8))
    #expect(r.dictations == 82 && r.words == 24_311 && r.typingWPM == 40)
    #expect(r.daily?.asOfLocalDate == date("2026-10-15"))
    #expect(r.daily?.days == [UsageReport.Day(date: date("2026-10-15"), count: 2, words: 5, recordingMs: 4000,
                                              fullElapsedMs: 4700, longestRecordingMs: 3000, mostWords: 3)])
  }

  @Test func decodesAnOlderCLIsReportWithoutDays() throws {
    let old = #"""
    {"command":"usage","schema_version":1,"coverage":{"status":"active","tracking_started_at":"2026-09-19T06:30:53Z"},
     "delivered_dictations":{"count":80},"processed_words":24306,"recording_duration_ms":8112000,
     "full_elapsed_duration_ms":8484000,"typing_assumption":{"wpm":40},"estimated_time_difference_ms":27975000}
    """#
    let r = try JSONDecoder().decode(UsageReport.self, from: Data(old.utf8))
    #expect(r.daily == nil)
    let stats = UsageStats(report: r, today: date("2026-10-15"), timeZone: utc)
    #expect(!stats.hasDaily && stats.lifetime.words == 24_306 && stats.lifetime.wordsPerMinute == 180)
  }

  @Test func rejectsMalformedValues() {
    for bad in [#""count":2,"words":5"#: #""count":-2,"words":5"#,
                #""date":"2026-10-15""#: #""date":"yesterday""#,
                #""words":5"#: #""words":"five""#,
                #""schema_version":1"#: #""schema_version":2"#] {
      let json = new.replacingOccurrences(of: bad.key, with: bad.value)
      #expect(json != new)
      #expect(throws: DecodingError.self) { try JSONDecoder().decode(UsageReport.self, from: Data(json.utf8)) }
    }
  }
}

struct UsageStatsTests {
  @Test func streakCountsUpToTodayOrYesterday() {
    let days = [day("2026-10-10", count: 1), day("2026-10-12", count: 2), day("2026-10-13", count: 1),
                day("2026-10-14", count: 4)]
    var stats = UsageStats(report: report(days: days, today: "2026-10-14"), today: date("2026-10-14"), timeZone: utc)
    #expect(stats.streak == UsageStats.Streak(current: 3, pendingToday: false, best: 3, bestEnded: date("2026-10-14")))
    // Next morning, nothing yet: the streak stands and can grow today.
    stats = UsageStats(report: report(days: days, today: "2026-10-15"), today: date("2026-10-15"), timeZone: utc)
    #expect(stats.streak.current == 3 && stats.streak.pendingToday)
    // A day missed: it's over, but the best is kept.
    stats = UsageStats(report: report(days: days, today: "2026-10-16"), today: date("2026-10-16"), timeZone: utc)
    #expect(stats.streak.current == 0 && !stats.streak.pendingToday && stats.streak.best == 3)
  }

  @Test func streakRunsAcrossMonthAndYearEnds() {
    let days = ["2026-12-30", "2026-12-31", "2027-01-01"].map { day($0, count: 1) }
    let stats = UsageStats(report: report(days: days, today: "2027-01-01", started: "2026-12-01T00:00:00Z"),
                           today: date("2027-01-01"), timeZone: utc)
    #expect(stats.streak.current == 3)
  }

  @Test func recordsPreferTheEarliestDayOnATieAndFlagRecentOnes() {
    let days = [day("2026-10-02", count: 1, words: 900, longest: 125_000),
                day("2026-10-05", count: 3, words: 900, longest: 20_000),
                day("2026-10-12", count: 2, words: 400, longest: 130_000)]
    let stats = UsageStats(report: report(days: days, today: "2026-10-14"), today: date("2026-10-14"), timeZone: utc)
    #expect(stats.records.bestDay == UsageStats.Record(value: 900, date: date("2026-10-02"), isNew: false))
    #expect(stats.records.longestTake == UsageStats.Record(value: 130_000, date: date("2026-10-12"), isNew: true))
    #expect(stats.records.longestStreak?.value == 1)
  }

  @Test func rangeLeavesOutDaysBeforeTrackingBegan() {
    let days = [day("2026-10-13", count: 2, words: 300, recordingMs: 60_000),
                day("2026-10-14", count: 1, words: 60, recordingMs: 60_000)]
    let stats = UsageStats(report: report(days: days, today: "2026-10-14", started: "2026-10-13T05:00:00Z"),
                           today: date("2026-10-14"), timeZone: utc)
    let range = stats.range(days: 30)
    #expect(range.words == 360 && range.dictations == 3 && range.untrackedDays == 28)
    #expect(range.wordsPerMinute == 180)
    #expect(stats.todayDictations == 1 && stats.todayWords == 60)
  }

  @Test func heatmapLaysOutWeeksFromTheLocaleWeekStart() throws {
    let days = [day("2026-10-14", count: 1), day("2026-10-13", count: 4), day("2026-10-12", count: 7),
                day("2026-10-11", count: 12)]
    let stats = UsageStats(report: report(days: days, today: "2026-10-14", started: "2026-10-11T05:00:00Z"),
                           today: date("2026-10-14"), firstWeekday: 2, timeZone: utc)
    let grid = stats.heatmap(days: 30)
    #expect(grid.allSatisfy { $0.count == 7 })
    #expect(grid.first?.first?.date.weekday == 2) // Monday rows first
    #expect(grid.flatMap { $0 }.filter { $0.state != .outsideRange && $0.state != .future }.count == 30)
    let cells = Dictionary(uniqueKeysWithValues: grid.flatMap { $0 }.map { ($0.date, $0.state) })
    #expect(cells[date("2026-10-14")] == .level(1))
    #expect(cells[date("2026-10-13")] == .level(2))
    #expect(cells[date("2026-10-12")] == .level(3))
    #expect(cells[date("2026-10-11")] == .level(4))
    #expect(cells[date("2026-10-10")] == .untracked)
    #expect(cells[date("2026-10-15")] == .future)
    let sunday = UsageStats(report: report(days: days, today: "2026-10-14"), today: date("2026-10-14"),
                            firstWeekday: 1, timeZone: utc)
    #expect(sunday.heatmap(days: 90).first?.first?.date.weekday == 1)
    #expect(sunday.heatmap(days: 90).flatMap { $0 }.filter { $0.state != .outsideRange && $0.state != .future }.count == 90)
    #expect(stats.heatmap(days: 60).flatMap { $0 }.contains { $0.date == date("2026-10-14").adding(days: -59) && $0.state != .outsideRange })
  }

  @Test func levelsFollowTheDictationCount() {
    #expect([0, 1, 2, 3, 5, 6, 9, 10, 40].map(UsageStats.level(dictations:)) == [0, 1, 1, 2, 2, 3, 3, 4, 4])
  }

  @Test func emptyAndTrackedButIdleDaysDiffer() {
    let stats = UsageStats(report: report(days: [day("2026-10-14", count: 1)], today: "2026-10-14",
                                          started: "2026-10-12T05:00:00Z"), today: date("2026-10-14"), timeZone: utc)
    let cells = Dictionary(uniqueKeysWithValues: stats.heatmap(days: 30).flatMap { $0 }.map { ($0.date, $0.state) })
    #expect(cells[date("2026-10-13")] == .empty)
    #expect(cells[date("2026-10-11")] == .untracked)
  }

  @Test func incompleteCoverageIsVisible() {
    let stats = UsageStats(report: report(days: [day("2026-10-14", count: 1)], today: "2026-10-14", untracked: 3),
                           today: date("2026-10-14"), timeZone: utc)
    #expect(!stats.coverageComplete && stats.untrackedDeliveries == 3)
  }

  @Test func unreadableDailyMeansLifetimeOnly() {
    var r = report(days: [], today: "2026-10-14")
    r = UsageReport(trackingStartedAt: r.trackingStartedAt, dictations: r.dictations, words: r.words,
                    recordingMs: r.recordingMs, fullElapsedMs: r.fullElapsedMs, typingWPM: r.typingWPM,
                    estimatedTimeDifferenceMs: r.estimatedTimeDifferenceMs,
                    daily: UsageReport.Daily(status: "unreadable", startedAt: nil, asOfLocalDate: date("2026-10-14"),
                                             untrackedDeliveries: 0, days: []))
    let stats = UsageStats(report: r, today: date("2026-10-14"), timeZone: utc)
    #expect(!stats.hasDaily && stats.dailyStatus == "unreadable")
  }

  @Test func negativeEstimatesStayNegative() {
    let r = UsageReport(trackingStartedAt: nil, dictations: 1, words: 2, recordingMs: 60_000, fullElapsedMs: 61_000,
                        typingWPM: 40, estimatedTimeDifferenceMs: -58_000, daily: nil)
    #expect(UsageStats(report: r, today: date("2026-10-14"), timeZone: utc).lifetime.estimatedSavedMs == -58_000)
  }

  @Test func milestonesProgressAndCelebrateOnce() {
    #expect(UsageStats.milestone(words: 0) == UsageStats.Milestone(previous: 0, next: 1_000, progress: 0))
    #expect(UsageStats.milestone(words: 24_306).next == 25_000)
    #expect(UsageStats.milestone(words: 24_306).previous == 10_000)
    #expect(UsageStats.milestone(words: 2_400_000) == UsageStats.Milestone(previous: 2_000_000, next: 3_000_000, progress: 0.4))
    // First open with existing totals: nothing to celebrate.
    #expect(UsageStats.milestoneCrossed(words: 24_306, lastSeen: nil) == nil)
    // Several crossed between openings: only the highest.
    #expect(UsageStats.milestoneCrossed(words: 52_000, lastSeen: 24_306) == 50_000)
    #expect(UsageStats.milestoneCrossed(words: 26_000, lastSeen: 25_100) == nil)
  }
}

struct StatsRefreshTests {
  @Test func coalescesToOneRunningAndOnePending() {
    var refresh = StatsRefresh()
    #expect(refresh.request() == 0)
    #expect(refresh.request() == nil)
    #expect(refresh.request() == nil)
    let first = refresh.finished(generation: 0)
    #expect(first.show && first.again == 0)
    let second = refresh.finished(generation: 0)
    #expect(second.show && second.again == nil && !refresh.running)
  }

  @Test func dropsALoadFromAClosedWindow() {
    var refresh = StatsRefresh()
    #expect(refresh.request() == 0)
    refresh.invalidate()
    let stale = refresh.finished(generation: 0)
    #expect(!stale.show && stale.again == nil && !refresh.running)
  }

  @Test func aReopenWaitsForTheLoadStillInFlight() {
    var refresh = StatsRefresh()
    #expect(refresh.request() == 0)
    refresh.invalidate()
    // Reopened while the old load runs: queued, not a second load.
    #expect(refresh.request() == nil)
    #expect(refresh.request() == nil)
    let stale = refresh.finished(generation: 0)
    #expect(!stale.show && stale.again == 1)
    #expect(refresh.request() == nil)
    let fresh = refresh.finished(generation: 1)
    #expect(fresh.show && fresh.again == 1)
    #expect(refresh.finished(generation: 1).again == nil && !refresh.running)
  }

  @Test func closingDropsAQueuedReload() {
    var refresh = StatsRefresh()
    #expect(refresh.request() == 0)
    #expect(refresh.request() == nil)
    refresh.invalidate()
    let stale = refresh.finished(generation: 0)
    #expect(!stale.show && stale.again == nil && !refresh.running)
  }

  @Test func debounceNeverPostponesPastTheCap() {
    var refresh = StatsRefresh()
    #expect(refresh.delayForChange(at: 10) == StatsRefresh.debounce)
    #expect(refresh.delayForChange(at: 11) == StatsRefresh.debounce)
    #expect(abs(refresh.delayForChange(at: 11.9) - 0.1) < 0.0001)
    #expect(refresh.delayForChange(at: 12.5) == 0)
    _ = refresh.request()
    #expect(refresh.delayForChange(at: 20) == StatsRefresh.debounce)
  }
}
