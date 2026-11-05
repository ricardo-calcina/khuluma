import KhulumaCore
import SwiftUI

/// The stats window. All the maths is in `UsageStats`; this only lays it out.
struct StatsView: View {
  @ObservedObject var model: StatsModel
  var minimumHeight: CGFloat? = nil

  var body: some View {
    Group {
      if let stats = model.stats {
        StatsContent(stats: stats, model: model,
                     minimumHeight: minimumHeight.map { max(0, $0 - 24) })
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
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
  let minimumHeight: CGFloat?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Card { Hero(lifetime: stats.lifetime) }
      Card { activitySection }
      Highlights(stats: stats)
      Card { progressSection }
    }
    .frame(minHeight: minimumHeight, alignment: .top)
  }

  private var activitySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.refreshFailed {
        Notice(symbol: "exclamationmark.triangle",
               text: "Couldn't refresh. Showing the last available stats.")
      }
      switch stats.dailyStatus {
      case nil, "unreadable":
        Text("Activity").font(.headline)
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
      }
    }
  }

  private var progressSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      RecordingTime(stats: stats)
      Divider()
      MilestoneProgress(milestone: stats.milestone, words: stats.lifetime.words,
                        reached: model.celebrating)
    }
  }
}

/// A grouped box, as in System Settings: white on the window in light mode,
/// a lighter fill in dark mode, with a hairline edge.
private struct Card<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder let content: Content
  @Environment(\.colorScheme) private var colorScheme

  static var radius: CGFloat { 10 }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color(nsColor: .controlBackgroundColor),
                  in: shape)
      .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
  }
}

/// A white SF Symbol on a small coloured rounded square, like the icons in
/// System Settings.
private struct SymbolBadge: View {
  let symbol: String
  let color: Color
  var size: CGFloat = 20

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(color.gradient)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: symbol)
          .font(.system(size: size * 0.55, weight: .semibold))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)
  }
}

// MARK: - Hero

/// The lifetime figures, as in the menu: the titles say it's all time.
/// Equal columns keep all three figures easy to scan.
private struct Hero: View {
  let lifetime: UsageStats.Lifetime
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      figure("Total words", value: lifetime.words.formatted(), tracking: Double(lifetime.words),
             caption: lifetime.since.map { "since \($0.formatted(.dateTime.day().month(.abbreviated).year()))" })
      Divider().frame(height: 56).padding(.top, 4)
      timeSaved
      Divider().frame(height: 56).padding(.top, 4)
      figure("Average WPM", value: lifetime.wordsPerMinute.map { $0.formatted() } ?? "–",
             tracking: Double(lifetime.wordsPerMinute ?? 0),
             info: "Words per minute of recording, including pauses.", caption: "pauses included")
    }
    .padding(.vertical, 2)
    .fixedSize(horizontal: false, vertical: true)
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
    VStack(spacing: 2) {
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText(value: tracking ?? 0))
        .animation(reduceMotion ? nil : .default, value: value)
      Text(caption ?? " ")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
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

  /// The content width inside the window's 20-point insets and the card's
  /// 14-point padding.
  static let width: CGFloat = 492

  /// Heatmap only (Words per day off); 30 days with the chart beside it;
  /// longer ranges with the chart under it, so both get the full width.
  private enum Layout { case heatmapOnly, sideBySide, stacked }

  private var layout: Layout {
    guard showWords else { return .heatmapOnly }
    return rangeDays > 30 ? .stacked : .sideBySide
  }

  /// The window never changes width: beside the chart the heatmap gets a
  /// fixed area with cells of at most 24 points; on its own row its cells
  /// stretch so the weeks fill the width.
  private func cellWidth(weeks: Int) -> CGFloat {
    let columns = CGFloat(max(weeks, 1))
    let area = layout == .sideBySide ? Heatmap.area : Self.width
    let width = ((area - Heatmap.labelColumn) / columns - Heatmap.gap).rounded(.down)
    return layout == .sideBySide ? min(24, width) : width
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
      let heatmap = Heatmap(weeks: weeks, today: stats.today, coverageComplete: stats.coverageComplete,
                            cellWidth: cellWidth(weeks: weeks.count), hovered: $hover.cell)
      Group {
        switch layout {
        case .heatmapOnly:
          heatmap
        case .sideBySide:
          HStack(alignment: .top, spacing: 24) {
            heatmap
            WordsPerDay(days: days, height: Heatmap.cellHeight * 7 + Heatmap.gap * 6, hovered: $hover.cell)
          }
        case .stacked:
          VStack(alignment: .leading, spacing: 10) {
            heatmap
            WordsPerDay(days: days, height: WordsPerDay.stackedHeight, hovered: $hover.cell)
          }
        }
      }
      .padding(.top, 2)
      HStack(alignment: .center, spacing: 8) {
        // Takes whatever width the legend leaves, whatever it says, so
        // hovering from day to day never moves anything.
        Text(hover.cell.map { Format.cellLine($0, coverageComplete: stats.coverageComplete) } ?? " ")
          .font(.callout)
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        Legend(showUntracked: weeks.joined().contains { $0.state == .untracked })
      }
      .frame(width: Self.width)
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

  /// Under the heatmap the bars are wide, so they can be shorter.
  static let stackedHeight: CGFloat = 64

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
      Text("More")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize()
    .help("A day's colour is how many dictations it had: 1–2, 3–5, 6–9, 10 or more.")
  }
}

// MARK: - Highlights, recording time and milestone

/// Streak and records as four tiles, each with its own symbol.
private struct Highlights: View {
  let stats: UsageStats

  var body: some View {
    let records = stats.records
    HStack(spacing: 10) {
      tile(stats.coverageComplete ? "Current streak" : "Recorded streak", symbol: "flame.fill", color: .orange,
           value: stats.hasDaily ? days(stats.streak.current) : "–",
           detail: stats.hasDaily ? (stats.streak.pendingToday ? "dictate today to keep it" : "in a row") : " ",
           help: "Days in a row with a dictation, up to today.")
      tile("Best day", symbol: "rosette", color: .pink,
           value: records.bestDay.map { "\($0.value.formatted()) words" } ?? "–",
           detail: date(records.bestDay),
           help: "Most words in a recorded day, across all daily stats.")
      tile("Longest take", symbol: "trophy.fill", color: .yellow,
           value: records.longestTake.map { Format.duration(ms: $0.value) } ?? "–",
           detail: date(records.longestTake),
           help: "Longest single recording, including pauses, across all daily stats.")
      tile("Longest streak", symbol: "calendar", color: .green,
           value: records.longestStreak.map { days($0.value) } ?? "–",
           detail: records.longestStreak.map { "ended \(Format.recordDate($0.date))" } ?? " ",
           help: "Longest run of recorded days. The date is the last day of that run.")
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func days(_ count: Int) -> String {
    "\(count) day\(count == 1 ? "" : "s")"
  }

  private func date(_ record: UsageStats.Record?) -> String {
    record.map { Format.recordDate($0.date) } ?? " "
  }

  private func tile(_ title: String, symbol: String, color: Color, value: String, detail: String,
                    help: String) -> some View {
    Card(padding: 10) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          SymbolBadge(symbol: symbol, color: color)
          Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(value)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value == "–" ? "No recorded value" : "\(value), \(detail)")
  }
}

private struct RecordingTime: View {
  let stats: UsageStats

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      SymbolBadge(symbol: "mic.fill", color: .red)
      Text("Recording time")
      Spacer(minLength: 0)
      figure(Format.duration(ms: stats.lifetime.recordingMs), label: "all time")
      Text("·").foregroundStyle(.tertiary)
      figure(today, label: "today")
    }
    .font(.callout)
    .help("Time spent recording successful dictations, including pauses. Today requires daily stats.")
    .accessibilityElement(children: .combine)
  }

  private func figure(_ value: String, label: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(value).monospacedDigit().fontWeight(.medium)
      Text(label).foregroundStyle(.secondary)
    }
  }

  private var today: String {
    stats.hasDaily ? Format.duration(ms: stats.todayRecordingMs) : "–"
  }
}

// MARK: - Word milestone

private struct MilestoneProgress: View {
  let milestone: UsageStats.Milestone
  let words: Int
  let reached: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let reached {
        Label("\(reached.formatted()) words reached", systemImage: "party.popper.fill")
          .font(.callout.weight(.medium))
      }
      HStack(alignment: .center, spacing: 8) {
        SymbolBadge(symbol: "flag.checkered", color: .blue)
        Text("Next milestone")
        Text("\(milestone.next.formatted()) words").fontWeight(.medium)
        Spacer()
        Text("\((milestone.next - words).formatted()) to go")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .font(.callout)
      ProgressView(value: progress, total: 1)
        .progressViewStyle(MilestoneProgressStyle())
        .help("\(words.formatted()) of \(milestone.next.formatted()) words toward the next milestone.")
        .accessibilityLabel("Progress to \(milestone.next.formatted()) words")
        .accessibilityValue("\(Int(progress * 100)) percent, \(words.formatted()) of \(milestone.next.formatted()) words, \((milestone.next - words).formatted()) words remaining")
    }
  }

  private var progress: Double {
    min(max(milestone.progress, 0), 1)
  }
}

private struct MilestoneProgressStyle: ProgressViewStyle {
  func makeBody(configuration: Configuration) -> some View {
    let progress = min(max(configuration.fractionCompleted ?? 0, 0), 1)
    GeometryReader { geometry in
      Capsule()
        .fill(.quaternary)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: geometry.size.width * progress)
        }
    }
    .frame(height: 8)
  }
}

// MARK: - Usage information

struct StatsDetailsView: View {
  @ObservedObject var model: StatsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Usage information").font(.headline)
      if let stats = model.stats {
        Text(Format.coverage(stats))
      } else {
        Text("Usage data hasn't been loaded yet.")
      }
      Text("Counts and durations only, never what you said.")
        .foregroundStyle(.secondary)
      Divider()
      if model.refreshFailed {
        Label(model.stats == nil ? "Couldn't load usage data. Try refreshing."
                : "Couldn't refresh. The displayed stats are from the last successful update.",
              systemImage: "exclamationmark.triangle")
      }
      Text(updatedLine)
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .padding(16)
    .frame(width: 292, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var updatedLine: String {
    if let updated = model.updatedAt {
      return "Updated \(updated.formatted(date: .abbreviated, time: .shortened))"
    } else {
      return "Not updated yet"
    }
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

  /// "15 Oct", or "15 Oct 2025" outside the current year.
  static func recordDate(_ date: CivilDate) -> String {
    let thisYear = Calendar.current.component(.year, from: Date())
    return date.components.year == thisYear ? shortDate(date) : formatted(date, template: "dMMMyyyy")
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
