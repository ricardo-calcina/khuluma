import KhulumaCore
import SwiftUI

/// The stats window. All the maths is in `UsageStats`; this only lays it out.
struct StatsView: View {
  @ObservedObject var model: StatsModel
  var body: some View {
    Group {
      if let stats = model.stats {
        StatsContent(stats: stats, model: model)
          .padding(20)
      } else if model.refreshFailed {
        Placeholder(symbol: "exclamationmark.triangle", text: "Couldn't load stats.") {
          Button("Try Again") { model.reload() }
        }
      } else {
        Placeholder(symbol: nil, text: "Loading stats…") { ProgressView().controlSize(.small) }
      }
    }
    .frame(width: 560)
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
      Hero(lifetime: stats.lifetime)
      Divider()
      switch stats.dailyStatus {
      case nil, "unreadable":
        Notice(symbol: "exclamationmark.triangle",
               text: "Daily stats couldn't be read. Lifetime totals are unaffected.")
      default:
        if stats.dailyStatus == "not_started" {
          Notice(symbol: "calendar.badge.clock", text: "Daily stats start with your next dictation.")
        }
        Activity(stats: stats, rangeDays: $model.rangeDays, showWords: $model.showWordsPerDay)
        if !stats.coverageComplete {
          Notice(symbol: "info.circle",
                 text: "\(stats.untrackedDeliveries.formatted()) dictation\(stats.untrackedDeliveries == 1 ? " was" : "s were") "
                   + "recorded without a day (by an earlier version), so daily figures are lower bounds.")
        }
        Divider()
        StreakSection(stats: stats)
      }
      Footer(stats: stats, model: model)
    }
  }
}

// MARK: - Hero

/// A quiet lifetime summary. Equal columns keep all three figures easy to scan.
private struct Hero: View {
  let lifetime: UsageStats.Lifetime
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 16) {
      Text("All time")
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 12) {
        figure("Total words", value: lifetime.words.formatted(), tracking: Double(lifetime.words))
        timeSaved
        figure("Average WPM", value: lifetime.wordsPerMinute.map { $0.formatted() } ?? "–",
               tracking: Double(lifetime.wordsPerMinute ?? 0),
               info: "Words per minute of recording, including pauses.", caption: "pauses included")
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var timeSaved: some View {
    if lifetime.words > 0 {
      let parts = Format.typingDifferenceParts(ms: lifetime.estimatedSavedMs)
      figure("Time saved", value: Format.savedTime(ms: lifetime.estimatedSavedMs), tracking: nil,
             info: "Typing the same words at \(lifetime.typingWPM) words per minute, minus the time from starting "
               + "a recording to its text arriving. An estimate: your typing speed will differ.",
             caption: parts.caption)
    } else {
      figure("Time saved", value: "–", tracking: nil, caption: "no dictations yet")
    }
  }

  private func figure(_ title: String, value: String, tracking: Double?,
                      info: String? = nil, caption: String? = nil) -> some View {
    VStack(spacing: 6) {
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 28, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText(value: tracking ?? 0))
        .animation(reduceMotion ? nil : .default, value: value)
      if let caption {
        Text(caption).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      } else {
        Text(" ").font(.caption).accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity)
    .help(info ?? title)
    .accessibilityElement(children: .combine)
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
  @Binding var showWords: Bool
  // Not @State: the Command Line Tools have no SwiftUI macro plugin.
  @StateObject private var hover = Hover()

  /// Cells narrow as the range grows, so the heatmap and the chart always
  /// share one row and the window keeps the same height for every range.
  /// The window never changes width: the heatmap gets a fixed area and its
  /// cells shrink to fit the range's weeks.
  private func cellWidth(weeks: Int) -> CGFloat {
    let columns = CGFloat(max(weeks, 1))
    return min(24, ((Heatmap.area - Heatmap.labelColumn) / columns - Heatmap.gap).rounded(.down))
  }

  var body: some View {
    let range = stats.range(days: rangeDays)
    let weeks = stats.heatmap(days: rangeDays)
    let days = weeks.joined().filter { $0.state != .outsideRange && $0.state != .future }
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Text("Activity").font(.headline)
        Spacer()
        Toggle("Words per day", isOn: $showWords)
          .toggleStyle(.switch)
          .controlSize(.mini)
          .font(.callout)
          .foregroundStyle(.secondary)
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
      HStack(alignment: .top, spacing: 24) {
        Heatmap(weeks: weeks, today: stats.today, coverageComplete: stats.coverageComplete,
                cellWidth: cellWidth(weeks: weeks.count), hovered: $hover.cell)
        if showWords {
          WordsPerDay(days: days, height: Heatmap.cellHeight * 7 + Heatmap.gap * 6, hovered: $hover.cell)
        }
      }
      .padding(.top, 2)
      HStack(alignment: .center) {
        Text(hover.cell.map { Format.cellLine($0, coverageComplete: stats.coverageComplete) } ?? " ")
          .font(.callout)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .truncationMode(.tail)
        Spacer(minLength: 8)
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
  let cellWidth: CGFloat
  @Binding var hovered: UsageStats.Cell?

  static let cellHeight: CGFloat = 18
  static let gap: CGFloat = 3
  /// Width of the weekday labels, and of the area the cells share at most.
  static let labelColumn: CGFloat = 18
  static let area: CGFloat = 270

  var body: some View {
    HStack(alignment: .top, spacing: Self.gap) {
      VStack(alignment: .trailing, spacing: Self.gap) {
        Text(" ").font(.caption2)
        ForEach(0..<7, id: \.self) { row in
          Text(Format.weekdaySymbol(weeks.first?[row].date))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: Self.labelColumn - Self.gap, height: Self.cellHeight, alignment: .trailing)
        }
      }
      ForEach(weeks.indices, id: \.self) { index in
        VStack(spacing: Self.gap) {
          Text(Format.monthLabel(week: weeks[index], isFirst: index == 0))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
          ForEach(weeks[index], id: \.date) { cell in
            HeatCell(cell: cell, isToday: cell.date == today, coverageComplete: coverageComplete,
                     width: cellWidth)
              .onHover { inside in
                if inside {
                  hovered = cell
                } else if hovered?.date == cell.date {
                  hovered = nil
                }
              }
          }
        }
        .frame(width: cellWidth)
      }
    }
  }
}

private struct HeatCell: View {
  let cell: UsageStats.Cell
  let isToday: Bool
  let coverageComplete: Bool
  let width: CGFloat

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
    .frame(width: width)
    .frame(height: Heatmap.cellHeight)
    .accessibilityElement()
    .accessibilityLabel(Format.cellLine(cell, coverageComplete: coverageComplete))
  }
}

/// One bar per day, sharing the heatmap's hover line. Drawn by hand: it is
/// only bars, and this avoids a framework for them.
private struct WordsPerDay: View {
  let days: [UsageStats.Cell]
  let height: CGFloat
  @Binding var hovered: UsageStats.Cell?

  var body: some View {
    let peak = days.map(\.words).max() ?? 0
    VStack(alignment: .leading, spacing: Heatmap.gap) {
      HStack {
        Text("Words per day")
        Spacer()
        if peak > 0 {
          Text("peak \(peak.formatted())").monospacedDigit()
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(height: 12)
      HStack(alignment: .bottom, spacing: days.count > 45 ? 1 : 2) {
        ForEach(days, id: \.date) { cell in
          ZStack(alignment: .bottom) {
            Color.clear
            if cell.words > 0 {
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor.opacity(hovered?.date == cell.date ? 1 : 0.75))
                .frame(height: max(2, height * Double(cell.words) / Double(peak)))
            }
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside {
              hovered = cell
            } else if hovered?.date == cell.date {
              hovered = nil
            }
          }
        }
      }
      .frame(height: height)
      .overlay(alignment: .bottom) {
        Rectangle().fill(.quaternary).frame(height: 1)
      }
      .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity)
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
    .fixedSize()
    .help("A day's colour is how many dictations it had: 1–2, 3–5, 6–9, 10 or more.")
  }
}

// MARK: - Streak

private struct StreakSection: View {
  let stats: UsageStats

  var body: some View {
    let streak = stats.streak
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label(streakTitle, systemImage: "flame")
          .font(.callout.weight(.medium))
          .monospacedDigit()
        Spacer()
        if streak.best > 0 {
          Text("Best \(streak.best) day\(streak.best == 1 ? "" : "s")")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      if streak.pendingToday {
        Text("Dictate today to make it \(streak.current + 1)")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var streakTitle: String {
    let days = stats.streak.current
    let label = stats.coverageComplete ? "streak" : "recorded streak"
    return "\(days)-day \(label)"
  }
}

// MARK: - Footer

private struct Footer: View {
  let stats: UsageStats
  @ObservedObject var model: StatsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Divider().padding(.bottom, 4)
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 2) {
          Text(Format.coverage(stats)).foregroundStyle(.secondary)
          Text("Counts and durations only, never what you said.").foregroundStyle(.secondary)
          Text(updatedLine).foregroundStyle(model.refreshFailed ? Color.orange : Color.secondary)
        }
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

  /// A signed estimate: a negative value means dictating took longer than typing.
  static func savedTime(ms: Int) -> String {
    typingDifferenceParts(ms: ms).amount
  }

  /// "≈ 7.9 h" and "faster than typing", or a negative estimate when slower.
  static func typingDifferenceParts(ms: Int) -> (amount: String, caption: String) {
    let minutes = abs(Double(ms)) / 60_000
    let amount = minutes >= 60
      ? "\((minutes / 60).formatted(.number.precision(.fractionLength(1)))) h"
      : "\(Int(minutes.rounded())) min"
    return ("≈ \(ms < 0 ? "−" : "")\(amount)", ms >= 0 ? "faster than typing" : "slower than typing")
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
