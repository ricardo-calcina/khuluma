import KhulumaCore
import SwiftUI

/// The stats window. All the maths is in `UsageStats`; this only lays it out.
struct StatsView: View {
  @ObservedObject var model: StatsModel
  /// Off for snapshots, which render the whole content at its full height.
  var scrolls = true

  var body: some View {
    Group {
      if let stats = model.stats, scrolls {
        ScrollView {
          StatsContent(stats: stats, model: model)
            .padding(20)
        }
      } else if let stats = model.stats {
        StatsContent(stats: stats, model: model)
          .padding(20)
      } else if model.refreshFailed {
        Placeholder(symbol: "exclamationmark.triangle", text: "Couldn't load stats from tmux-whisper.") {
          Button("Try Again") { model.reload() }
        }
      } else {
        Placeholder(symbol: nil, text: "Loading stats…") { ProgressView().controlSize(.small) }
      }
    }
    .frame(minWidth: 480, minHeight: scrolls ? 400 : 0)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct Placeholder<Accessory: View>: View {
  let symbol: String?
  let text: String
  @ViewBuilder let accessory: Accessory

  var body: some View {
    VStack(spacing: 12) {
      if let symbol {
        Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
      }
      Text(text).foregroundStyle(.secondary)
      accessory
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct StatsContent: View {
  let stats: UsageStats
  @ObservedObject var model: StatsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let milestone = model.celebrating {
        Label("You passed \(milestone.formatted()) words", systemImage: "party.popper.fill")
          .font(.headline)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.15), in: Capsule())
      }
      Hero(lifetime: stats.lifetime)
      switch stats.dailyStatus {
      case nil, "unreadable":
        Notice(symbol: "exclamationmark.triangle",
               text: "Daily stats couldn't be read. Lifetime totals are unaffected.")
      default:
        if stats.dailyStatus == "not_started" {
          Notice(symbol: "calendar.badge.clock", text: "Daily stats start with your next dictation.")
        }
        Activity(stats: stats, rangeDays: $model.rangeDays)
        if !stats.coverageComplete {
          Notice(symbol: "info.circle",
                 text: "\(stats.untrackedDeliveries.formatted()) dictation\(stats.untrackedDeliveries == 1 ? " was" : "s were") "
                   + "recorded without a day (by an older tmux-whisper), so daily figures are lower bounds.")
        }
        HStack(alignment: .top, spacing: 12) {
          StreakCard(stats: stats)
            .frame(width: 170)
          RecordsCard(records: stats.records)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      Tiles(stats: stats)
      MilestoneBar(milestone: stats.milestone, words: stats.lifetime.words)
      Footer(stats: stats, model: model)
    }
  }
}

// MARK: - Hero

private struct Hero: View {
  let lifetime: UsageStats.Lifetime
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text(lifetime.words.formatted())
          .font(.system(size: 44, weight: .bold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(lifetime.words)))
          .animation(reduceMotion ? nil : .default, value: lifetime.words)
        Text("words dictated").foregroundStyle(.secondary)
        if lifetime.words > 0 {
          typingLine
        }
      }
      Spacer(minLength: 16)
      wpm
    }
  }

  private var typingLine: some View {
    HStack(spacing: 4) {
      Text(Format.typingDifference(ms: lifetime.estimatedSavedMs))
      Text("(estimate at \(lifetime.typingWPM) wpm)").foregroundStyle(.secondary)
      InfoMark("Typing the same words at \(lifetime.typingWPM) words per minute, minus the time from starting "
               + "a recording to its text arriving. An estimate: your typing speed will differ.")
    }
    .font(.callout)
    .padding(.top, 2)
  }

  private var wpm: some View {
    VStack(alignment: .trailing, spacing: 4) {
      Text(lifetime.wordsPerMinute.map { $0.formatted() } ?? "–")
        .font(.system(size: 44, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Color.accentColor)
        .contentTransition(.numericText(value: Double(lifetime.wordsPerMinute ?? 0)))
        .animation(reduceMotion ? nil : .default, value: lifetime.wordsPerMinute)
      HStack(spacing: 4) {
        Text("words per minute").foregroundStyle(.secondary)
        InfoMark("Words per minute of recording, pauses included.")
      }
    }
  }
}

private struct InfoMark: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Image(systemName: "info.circle")
      .foregroundStyle(.secondary)
      .help(text)
      .accessibilityLabel(text)
  }
}

private struct Notice: View {
  let symbol: String
  let text: String

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - Activity

private struct Activity: View {
  let stats: UsageStats
  @Binding var rangeDays: Int
  // Not @State: the Command Line Tools have no SwiftUI macro plugin.
  @StateObject private var hover = Hover()

  var body: some View {
    let range = stats.range(days: rangeDays)
    let weeks = stats.heatmap(days: rangeDays)
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Activity").font(.headline)
        Spacer()
        Picker("Range", selection: $rangeDays) {
          ForEach(StatsModel.ranges, id: \.self) { Text("\($0) days").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      Text(Format.rangeLine(range, since: stats.dailySince))
        .font(.callout)
        .foregroundStyle(.secondary)
      Heatmap(weeks: weeks, today: stats.today, coverageComplete: stats.coverageComplete, hovered: $hover.cell)
      HStack(alignment: .center) {
        Text(hover.cell.map { Format.cellLine($0, coverageComplete: stats.coverageComplete) } ?? " ")
          .font(.callout)
          .monospacedDigit()
        Spacer()
        Legend(showUntracked: weeks.joined().contains { $0.state == .untracked })
      }
    }
  }
}

@MainActor
private final class Hover: ObservableObject {
  @Published var cell: UsageStats.Cell?
}

private struct Heatmap: View {
  let weeks: [[UsageStats.Cell]]
  let today: CivilDate
  let coverageComplete: Bool
  @Binding var hovered: UsageStats.Cell?

  static let cell: CGFloat = 24
  static let gap: CGFloat = 4

  var body: some View {
    HStack(alignment: .top, spacing: Self.gap) {
      VStack(alignment: .trailing, spacing: Self.gap) {
        Text(" ").font(.caption2)
        ForEach(0..<7, id: \.self) { row in
          Text(Format.weekdaySymbol(weeks.first?[row].date))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(height: Self.cell)
        }
      }
      ForEach(weeks.indices, id: \.self) { index in
        VStack(spacing: Self.gap) {
          Text(Format.monthLabel(week: weeks[index], isFirst: index == 0))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(width: Self.cell, alignment: .leading)
          ForEach(weeks[index], id: \.date) { cell in
            HeatCell(cell: cell, isToday: cell.date == today, coverageComplete: coverageComplete)
              .onHover { inside in
                if inside {
                  hovered = cell
                } else if hovered?.date == cell.date {
                  hovered = nil
                }
              }
          }
        }
      }
    }
  }
}

private struct HeatCell: View {
  let cell: UsageStats.Cell
  let isToday: Bool
  let coverageComplete: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    ZStack {
      switch cell.state {
      case .outsideRange, .future:
        shape.fill(.clear)
      case .untracked:
        shape.strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
      case .empty:
        shape.fill(.quaternary)
      case .level(let level):
        shape.fill(HeatColor.fill(level))
      }
      if isToday {
        shape.strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
      }
    }
    .frame(width: Heatmap.cell, height: Heatmap.cell)
    .accessibilityElement()
    .accessibilityLabel(Format.cellLine(cell, coverageComplete: coverageComplete))
  }
}

enum HeatColor {
  /// Faint to solid; the faintest still stands apart from an empty day.
  static let opacities = [0.3, 0.55, 0.8, 1.0]

  static func fill(_ level: Int) -> Color {
    Color.accentColor.opacity(opacities[min(max(level, 1), opacities.count) - 1])
  }
}

private struct Legend: View {
  let showUntracked: Bool

  var body: some View {
    HStack(spacing: 4) {
      if showUntracked {
        RoundedRectangle(cornerRadius: 3)
          .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
          .frame(width: 11, height: 11)
        Text("not tracked").padding(.trailing, 8)
      }
      Text("Fewer")
      RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 11, height: 11)
      ForEach(1...4, id: \.self) { level in
        RoundedRectangle(cornerRadius: 3).fill(HeatColor.fill(level)).frame(width: 11, height: 11)
      }
      Text("More dictations")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .help("A day's colour is how many dictations it had: 1–2, 3–5, 6–9, 10 or more.")
  }
}

// MARK: - Streak and bests

private struct StreakCard: View {
  let stats: UsageStats

  var body: some View {
    let streak = stats.streak
    Card {
      Label(stats.coverageComplete ? "Streak" : "Recorded streak", systemImage: "flame.fill")
        .font(.headline)
        .foregroundStyle(streak.current > 0 ? Color.orange : Color.secondary)
      Text("\(streak.current) day\(streak.current == 1 ? "" : "s")")
        .font(.system(size: 28, weight: .bold, design: .rounded))
        .monospacedDigit()
      Text(streak.best == 0 ? "None yet"
           : streak.current > 1 && streak.current == streak.best
           ? "Your best streak yet" : "Best \(streak.best) day\(streak.best == 1 ? "" : "s")")
        .foregroundStyle(.secondary)
      if streak.pendingToday {
        Text("Dictate today to make it \(streak.current + 1)")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct RecordsCard: View {
  let records: UsageStats.Records

  var body: some View {
    Card {
      Label("Recorded bests", systemImage: "trophy.fill").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        row("Best day", records.bestDay) { "\($0.formatted()) words" }
        row("Longest take", records.longestTake) { Format.duration(ms: $0) }
        row("Longest streak", records.longestStreak) { "\($0) day\($0 == 1 ? "" : "s")" }
      }
    }
  }

  private func row(_ title: String, _ record: UsageStats.Record?, value: (Int) -> String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary).fixedSize()
      if let record {
        Text(value(record.value)).monospacedDigit().fixedSize()
        Text(Format.shortDate(record.date)).foregroundStyle(.secondary).fixedSize()
        if record.isNew {
          Text("New")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
        }
      } else {
        Text("–").foregroundStyle(.secondary)
      }
    }
  }
}

private struct Card<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) { content }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(12)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

// MARK: - Tiles, milestone, footer

private struct Tiles: View {
  let stats: UsageStats

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      tile("Dictations", value: stats.lifetime.dictations.formatted(),
           today: stats.hasDaily ? "\(stats.todayDictations.formatted()) today" : nil)
      tile("Recording time", value: Format.duration(ms: stats.lifetime.recordingMs),
           today: stats.hasDaily ? "\(Format.duration(ms: stats.todayRecordingMs)) today" : nil)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func tile(_ title: String, value: String, today: String?) -> some View {
    Card {
      Text(title).foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
      if let today {
        Text(today).font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}

private struct MilestoneBar: View {
  let milestone: UsageStats.Milestone
  let words: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Next milestone: \(milestone.next.formatted()) words").font(.callout)
        Spacer()
        Text("\((milestone.next - words).formatted()) to go")
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      ProgressView(value: milestone.progress)
        .progressViewStyle(.linear)
    }
  }
}

private struct Footer: View {
  let stats: UsageStats
  @ObservedObject var model: StatsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Divider().padding(.bottom, 6)
      Text(Format.coverage(stats)).foregroundStyle(.secondary)
      Text("Stats keep counts and durations only, never what you said.").foregroundStyle(.secondary)
      HStack {
        Text(updatedLine).foregroundStyle(model.refreshFailed ? Color.orange : Color.secondary)
        Spacer()
        Button {
          model.reload()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r")
      }
    }
    .font(.caption)
  }

  private var updatedLine: String {
    let time = model.updatedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–"
    return model.refreshFailed ? "Couldn't refresh · Updated \(time)" : "Updated \(time)"
  }
}

// MARK: - Formatting

enum Format {
  static func duration(ms: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    let seconds = Double(max(ms, 0)) / 1000
    formatter.allowedUnits = seconds < 60 ? [.second] : seconds < 3600 ? [.minute, .second] : [.hour, .minute]
    formatter.maximumUnitCount = 2
    return formatter.string(from: seconds) ?? "–"
  }

  /// "≈ 7.9 h faster than typing", or slower when dictating took longer.
  static func typingDifference(ms: Int) -> String {
    let minutes = Double(abs(ms)) / 60_000
    let amount = minutes >= 60
      ? "\((minutes / 60).formatted(.number.precision(.fractionLength(1)))) h"
      : "\(Int(minutes.rounded())) min"
    return ms >= 0 ? "≈ \(amount) faster than typing" : "≈ \(amount) slower than typing"
  }

  static func rangeLine(_ range: UsageStats.RangeSummary, since: CivilDate?) -> String {
    var head = "Last \(range.days) days"
    if range.untrackedDays == range.days {
      return head + ": not tracked yet"
    }
    if range.untrackedDays > 0 {
      head += since.map { " (tracked since \(shortDate($0)))" } ?? ""
    }
    var parts = ["\(range.words.formatted()) words", "\(range.dictations.formatted()) dictations"]
    if let wpm = range.wordsPerMinute {
      parts.append("\(wpm) wpm")
    }
    return head + ": " + parts.joined(separator: " · ")
  }

  /// With incomplete coverage a day may have had dictations recorded
  /// without a day, so an empty day only had none *recorded*.
  static func cellLine(_ cell: UsageStats.Cell, coverageComplete: Bool) -> String {
    let day = longDate(cell.date)
    switch cell.state {
    case .untracked: return "\(day): not tracked"
    case .future, .outsideRange: return day
    case .empty: return "\(day): no \(coverageComplete ? "" : "recorded ")dictations"
    case .level:
      var parts = ["\(cell.dictations) dictation\(cell.dictations == 1 ? "" : "s")", "\(cell.words.formatted()) words"]
      if let wpm = cell.wordsPerMinute {
        parts.append("\(wpm) wpm")
      }
      return "\(day): " + parts.joined(separator: " · ")
    }
  }

  static func coverage(_ stats: UsageStats) -> String {
    var parts: [String] = []
    if let since = stats.lifetime.since {
      parts.append("Totals since \(since.formatted(date: .abbreviated, time: .omitted))")
    }
    if let daily = stats.dailySince {
      parts.append("daily since \(shortDate(daily))")
    }
    return parts.isEmpty ? "No dictations recorded yet" : parts.joined(separator: " · ")
  }

  /// The month's short name above the week its 1st falls in, and above the
  /// first week when the next month is at least two weeks away (no overlap).
  static func monthLabel(week: [UsageStats.Cell], isFirst: Bool) -> String {
    let shown = week.filter { $0.state != .outsideRange && $0.state != .future }
    if let first = shown.first(where: { $0.date.components.day == 1 }) {
      return month(first.date)
    }
    guard isFirst, let first = shown.first, first.date.components.day <= 17 else { return "" }
    return month(first.date)
  }

  static func weekdaySymbol(_ date: CivilDate?) -> String {
    guard let date else { return "" }
    return Calendar.current.veryShortWeekdaySymbols[date.weekday - 1]
  }

  static func shortDate(_ date: CivilDate) -> String {
    formatted(date, template: "dMMM")
  }

  static func longDate(_ date: CivilDate) -> String {
    formatted(date, template: "EEEdMMM")
  }

  private static func month(_ date: CivilDate) -> String {
    formatted(date, template: "MMM")
  }

  private static func formatted(_ date: CivilDate, template: String) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date.noon)
  }
}

extension CivilDate {
  /// Midday on this date here, for formatting (noon avoids DST edges).
  var noon: Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let c = components
    return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? Date()
  }
}
