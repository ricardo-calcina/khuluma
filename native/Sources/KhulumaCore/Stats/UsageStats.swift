import Foundation

/// Everything the stats window shows, derived from a `UsageReport`. Pure:
/// "today" and the week start are inputs, so it tests without a clock.
public struct UsageStats: Equatable, Sendable {
  public struct Lifetime: Equatable, Sendable {
    public let dictations: Int
    public let words: Int
    public let recordingMs: Int
    /// Estimate: typing-equivalent at `typingWPM` minus record start → delivered.
    public let estimatedSavedMs: Int
    public let typingWPM: Int
    public let since: Date?

    /// Words per minute of recording (pauses included); nil before any.
    public var wordsPerMinute: Int? { UsageStats.wpm(words: words, recordingMs: recordingMs) }
  }

  public struct Streak: Equatable, Sendable {
    /// Days in a row up to today, or up to yesterday while today has none yet.
    public let current: Int
    /// The current streak can still grow today (yesterday counted, today not yet).
    public let pendingToday: Bool
    public let best: Int
    public let bestEnded: CivilDate?
  }

  public struct Record: Equatable, Sendable {
    public let value: Int
    public let date: CivilDate
    /// Set in the last 7 days.
    public let isNew: Bool
  }

  public struct Records: Equatable, Sendable {
    /// Most words in a day.
    public let bestDay: Record?
    /// Longest single recording (ms).
    public let longestTake: Record?
    /// Longest run of days, dated by the day it ended.
    public let longestStreak: Record?
  }

  public struct RangeSummary: Equatable, Sendable {
    public let days: Int
    public let words: Int
    public let dictations: Int
    public let recordingMs: Int
    /// Days of the range before daily tracking began (excluded from totals).
    public let untrackedDays: Int
    public var wordsPerMinute: Int? { UsageStats.wpm(words: words, recordingMs: recordingMs) }
  }

  public struct Cell: Equatable, Sendable {
    public enum State: Equatable, Sendable {
      /// Pads the first week before the range starts; drawn blank.
      case outsideRange
      /// Before daily tracking began: unknown, not idle.
      case untracked
      case empty
      case level(Int)
      /// After today, in the last week.
      case future
    }

    public let date: CivilDate
    public let state: State
    public let dictations: Int
    public let words: Int
    public let recordingMs: Int
    public var wordsPerMinute: Int? { UsageStats.wpm(words: words, recordingMs: recordingMs) }
  }

  public struct Milestone: Equatable, Sendable {
    public let previous: Int
    public let next: Int
    /// 0…1 from zero words to the next target.
    public let progress: Double
  }

  /// Heatmap intensity by dictations in a day: 1–2, 3–5, 6–9, 10+.
  public static let levelThresholds = [1, 3, 6, 10]
  public static let milestones = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]

  public let today: CivilDate
  public let lifetime: Lifetime
  /// The report has active daily buckets.
  public let hasDaily: Bool
  public let dailyStatus: String?
  /// The first day with daily data (local date of `daily.started_at`).
  public let dailySince: CivilDate?
  /// Deliveries with no day (older CLI); daily figures are then lower bounds.
  public let untrackedDeliveries: Int
  public let todayDictations: Int
  public let todayWords: Int
  public let todayRecordingMs: Int
  public let streak: Streak
  public let records: Records

  private let byDate: [CivilDate: UsageReport.Day]
  private let firstWeekday: Int

  public var coverageComplete: Bool { untrackedDeliveries == 0 }

  public init(report: UsageReport, today fallbackToday: CivilDate, firstWeekday: Int = 2,
              timeZone: TimeZone = .current) {
    let daily = report.daily?.status == "active" ? report.daily : nil
    today = daily?.asOfLocalDate ?? fallbackToday
    self.firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : 2
    lifetime = Lifetime(dictations: report.dictations, words: report.words, recordingMs: report.recordingMs,
                        estimatedSavedMs: report.estimatedTimeDifferenceMs, typingWPM: report.typingWPM,
                        since: report.trackingStartedAt)
    hasDaily = daily != nil
    dailyStatus = report.daily?.status
    untrackedDeliveries = daily?.untrackedDeliveries ?? 0
    var byDate: [CivilDate: UsageReport.Day] = [:]
    for day in daily?.days ?? [] where day.count > 0 {
      byDate[day.date] = day
    }
    self.byDate = byDate
    let firstDay = byDate.keys.min()
    let started = daily?.startedAt.map { CivilDate($0, timeZone: timeZone) }
    dailySince = [firstDay, started].compactMap { $0 }.min()
    let today = self.today
    todayDictations = byDate[today]?.count ?? 0
    todayWords = byDate[today]?.words ?? 0
    todayRecordingMs = byDate[today]?.recordingMs ?? 0
    let streak = Self.streak(dates: Set(byDate.keys), today: today)
    self.streak = streak
    records = Records(
      bestDay: Self.record(in: byDate.values, today: today, \.words),
      longestTake: Self.record(in: byDate.values, today: today, \.longestRecordingMs),
      longestStreak: streak.best > 0 ? streak.bestEnded.map {
        Record(value: streak.best, date: $0, isNew: Self.isRecent($0, today: today))
      } : nil)
  }

  /// Highest value; the earliest day wins a tie (it got there first).
  static func record(in days: some Collection<UsageReport.Day>, today: CivilDate,
                     _ value: (UsageReport.Day) -> Int) -> Record? {
    let best = days.filter { value($0) > 0 }
      .min { value($0) != value($1) ? value($0) > value($1) : $0.date < $1.date }
    return best.map { Record(value: value($0), date: $0.date, isNew: isRecent($0.date, today: today)) }
  }

  /// In the last 7 days, today included.
  static func isRecent(_ date: CivilDate, today: CivilDate) -> Bool {
    date >= today.adding(days: -6) && date <= today
  }

  /// The last `days` calendar dates including today, untracked days left out.
  public func range(days: Int) -> RangeSummary {
    let start = today.adding(days: -(max(days, 1) - 1))
    var words = 0, dictations = 0, recording = 0, untracked = 0
    for offset in 0..<max(days, 1) {
      let date = start.adding(days: offset)
      if let since = dailySince, date < since {
        untracked += 1
      } else if dailySince == nil {
        untracked += 1
      } else if let day = byDate[date] {
        words += day.words
        dictations += day.count
        recording += day.recordingMs
      }
    }
    return RangeSummary(days: max(days, 1), words: words, dictations: dictations, recordingMs: recording,
                        untrackedDays: untracked)
  }

  /// Heatmap columns (one per week, oldest first), each 7 cells starting on
  /// `firstWeekday`, covering the last `days` dates through today.
  public func heatmap(days: Int) -> [[Cell]] {
    let start = today.adding(days: -(max(days, 1) - 1))
    let lead = (start.weekday - firstWeekday + 7) % 7
    let gridStart = start.adding(days: -lead)
    let total = lead + max(days, 1)
    let weeks = (total + 6) / 7
    return (0..<weeks).map { week in
      (0..<7).map { row in
        let date = gridStart.adding(days: week * 7 + row)
        let day = byDate[date]
        let state: Cell.State
        if date > today {
          state = .future
        } else if date < start {
          state = .outsideRange
        } else if dailySince.map({ date < $0 }) ?? true {
          state = .untracked
        } else if let day {
          state = .level(Self.level(dictations: day.count))
        } else {
          state = .empty
        }
        return Cell(date: date, state: state, dictations: day?.count ?? 0, words: day?.words ?? 0,
                    recordingMs: day?.recordingMs ?? 0)
      }
    }
  }

  public var milestone: Milestone {
    Self.milestone(words: lifetime.words)
  }

  public static func level(dictations: Int) -> Int {
    levelThresholds.lastIndex { dictations >= $0 }.map { $0 + 1 } ?? 0
  }

  public static func milestone(words: Int) -> Milestone {
    let previous = milestones.last { $0 <= words } ?? 0
    let next = milestones.first { $0 > words } ?? ((words / 1_000_000) + 1) * 1_000_000
    let base = words >= 1_000_000 ? (words / 1_000_000) * 1_000_000 : previous
    let progress = Double(words) / Double(max(next, 1))
    return Milestone(previous: base, next: next, progress: min(max(progress, 0), 1))
  }

  /// The highest milestone passed since `lastSeen` words, if any: one
  /// celebration however many were crossed between openings.
  public static func milestoneCrossed(words: Int, lastSeen: Int?) -> Int? {
    guard let lastSeen else { return nil }
    let passed = milestone(words: words).previous
    return passed > lastSeen && passed > 0 && passed <= words ? passed : nil
  }

  static func wpm(words: Int, recordingMs: Int) -> Int? {
    guard recordingMs > 0, words > 0 else { return nil }
    return Int((Double(words) / (Double(recordingMs) / 60_000)).rounded())
  }

  static func streak(dates: Set<CivilDate>, today: CivilDate) -> Streak {
    func run(endingAt end: CivilDate) -> Int {
      var length = 0
      while dates.contains(end.adding(days: -length)) { length += 1 }
      return length
    }
    let current: Int
    let pending: Bool
    if dates.contains(today) {
      current = run(endingAt: today)
      pending = false
    } else {
      current = run(endingAt: today.adding(days: -1))
      pending = current > 0
    }
    var best = 0
    var bestEnded: CivilDate?
    for date in dates.sorted() where !dates.contains(date.adding(days: 1)) {
      let length = run(endingAt: date)
      if length > best {
        best = length
        bestEnded = date
      }
    }
    return Streak(current: current, pendingToday: pending, best: best, bestEnded: bestEnded)
  }
}
