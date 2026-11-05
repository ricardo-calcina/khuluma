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

  /// Space either side of a section's hairline.
  static let sectionGap: CGFloat = 16

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Hero(lifetime: stats.lifetime)
      SectionRule()
      activitySection
      SectionRule()
      Highlights(stats: stats)
      SectionRule()
      progressSection
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
    VStack(alignment: .leading, spacing: 14) {
      RecordingTime(stats: stats)
      MilestoneProgress(milestone: stats.milestone, words: stats.lifetime.words,
                        reached: model.celebrating)
    }
  }
}

/// A faint full-width hairline between sections, with equal space around it.
private struct SectionRule: View {
  var body: some View {
    Divider()
      .opacity(0.6)
      .padding(.vertical, StatsContent.sectionGap)
  }
}

// MARK: - Hero

/// The lifetime figures, as in the menu: the titles say it's all time.
/// Equal columns keep all three figures easy to scan.
private struct Hero: View {
  let lifetime: UsageStats.Lifetime
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      figure("Total words", value: lifetime.words.formatted(), tracking: Double(lifetime.words),
             caption: lifetime.since.map { "since \($0.formatted(.dateTime.day().month(.abbreviated).year()))" })
      timeSaved
      figure("Average WPM", value: lifetime.wordsPerMinute.map { $0.formatted() } ?? "–",
             tracking: Double(lifetime.wordsPerMinute ?? 0),
             info: "Words per minute of recording, including pauses.", caption: "pauses included")
    }
    .padding(.top, 4)
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
    VStack(spacing: 4) {
      Text(value)
        .font(.system(size: 32, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .contentTransition(.numericText(value: tracking ?? 0))
        .animation(reduceMotion ? nil : .default, value: value)
      Ink.label(title)
      Text(caption ?? " ")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
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

  /// The content width inside the window's 20-point insets.
  static let width: CGFloat = 520
  /// Words per day sits under the heatmap: its header, gap and bars.
  static let chartBlock: CGFloat = 10 + 12 + Heatmap.gap + WordsPerDay.height

  /// Activity is the same height for every range and with the chart on or
  /// off: without the chart the heatmap's rows take its height. Cells stay
  /// near square and the heatmap is centred when the weeks don't need the
  /// full width.
  private func cellSize(weeks: Int) -> CGSize {
    let height = showWords ? Heatmap.cellHeight
      : ((Heatmap.cellHeight * 7 + Self.chartBlock) / 7).rounded(.down)
    let columns = CGFloat(max(weeks, 1))
    let fit = ((Self.width - Heatmap.labelColumn) / columns - Heatmap.gap).rounded(.down)
    return CGSize(width: min(fit, (height * 1.3).rounded()), height: height)
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
      // The range's totals, or the hovered day's figures in their place. A
      // fixed frame and no scaling, so the text can never move anything.
      Text(hover.cell.map { Format.cellLine($0, coverageComplete: stats.coverageComplete) }
           ?? Format.rangeLine(range, since: stats.dailySince))
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(hover.cell == nil ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: Self.width, height: 18, alignment: .leading)
      VStack(alignment: .leading, spacing: 10) {
        Heatmap(weeks: weeks, today: stats.today, coverageComplete: stats.coverageComplete,
                cellSize: cellSize(weeks: weeks.count), hover: hover)
          .frame(width: Self.width)
        if showWords {
          WordsPerDay(days: days, hover: hover)
        }
      }
      .padding(.top, 2)
      HStack {
        Spacer()
        Legend(showUntracked: weeks.joined().contains { $0.state == .untracked })
      }
    }
  }
}

/// The hovered day. Leaving a day clears it only if no other day is entered
/// straight after, so crossing the gaps between cells doesn't flicker.
@MainActor
private final class Hover: ObservableObject {
  @Published private(set) var cell: UsageStats.Cell?
  private var pendingClear: DispatchWorkItem?

  func update(_ cell: UsageStats.Cell, inside: Bool) {
    if inside {
      pendingClear?.cancel()
      self.cell = cell
    } else if self.cell?.date == cell.date {
      pendingClear?.cancel()
      let clear = DispatchWorkItem { [weak self] in
        if self?.cell?.date == cell.date { self?.cell = nil }
      }
      pendingClear = clear
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: clear)
    }
  }
}

private struct Heatmap: View {
  let weeks: [[UsageStats.Cell]]
  let today: CivilDate
  let coverageComplete: Bool
  let cellSize: CGSize
  @ObservedObject var hover: Hover

  static let cellHeight: CGFloat = 20
  static let gap: CGFloat = 3
  /// Width of the weekday labels.
  static let labelColumn: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: Self.gap) {
      VStack(alignment: .trailing, spacing: Self.gap) {
        Text(" ").font(.caption2)
        ForEach(0..<7, id: \.self) { row in
          Text(Format.weekdaySymbol(weeks.first?[row].date))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: Self.labelColumn - Self.gap, height: cellSize.height, alignment: .trailing)
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
                     size: cellSize)
              .onHover { hover.update(cell, inside: $0) }
          }
        }
        .frame(width: cellSize.width)
      }
    }
  }
}

private struct HeatCell: View {
  let cell: UsageStats.Cell
  let isToday: Bool
  let coverageComplete: Bool
  let size: CGSize

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    ZStack {
      switch cell.state {
      case .outsideRange, .future:
        shape.fill(.clear)
      case .untracked:
        shape.strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
      case .empty:
        shape.fill(HeatColor.empty)
      case .level(let level):
        shape.fill(HeatColor.fill(level))
      }
      if isToday {
        // A ring in the gap around the cell, so it reads on any shade.
        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
          .inset(by: -2)
          .stroke(Ink.color.opacity(0.8), lineWidth: 1.2)
      }
    }
    .frame(width: size.width, height: size.height)
    .accessibilityElement()
    .accessibilityLabel(Format.cellLine(cell, coverageComplete: coverageComplete))
  }
}

/// One bar per day, sharing the heatmap's hover line. Drawn by hand: it is
/// only bars, and this avoids a framework for them.
private struct WordsPerDay: View {
  let days: [UsageStats.Cell]
  @ObservedObject var hover: Hover

  static let height: CGFloat = 64

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
                .fill(Ember.vertical)
                .opacity(hover.cell?.date == cell.date ? 1 : 0.8)
                .frame(height: max(2, Self.height * Double(cell.words) / Double(peak)))
            }
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
          .onHover { hover.update(cell, inside: $0) }
        }
      }
      .frame(height: Self.height)
      .overlay(alignment: .bottom) {
        Rectangle().fill(.quaternary).frame(height: 1)
      }
      .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity)
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
      RoundedRectangle(cornerRadius: 3).fill(HeatColor.empty).frame(width: 11, height: 11)
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

// MARK: - Highlights, recording time and milestone

/// Streak and records as four equal columns, each with its own symbol.
private struct Highlights: View {
  let stats: UsageStats

  var body: some View {
    let records = stats.records
    HStack(alignment: .top, spacing: 12) {
      tile(stats.coverageComplete ? "Current streak" : "Recorded streak", symbol: "flame.fill",
           value: stats.hasDaily ? days(stats.streak.current) : "–",
           detail: stats.hasDaily ? (stats.streak.pendingToday ? "dictate today to keep it" : "in a row") : " ",
           help: "Days in a row with a dictation, up to today.")
      tile("Best day", symbol: "rosette",
           value: records.bestDay.map { "\($0.value.formatted()) words" } ?? "–",
           detail: date(records.bestDay),
           help: "Most words in a recorded day, across all daily stats.")
      tile("Longest take", symbol: "trophy.fill",
           value: records.longestTake.map { Format.duration(ms: $0.value) } ?? "–",
           detail: date(records.longestTake),
           help: "Longest single recording, including pauses, across all daily stats.")
      tile("Longest streak", symbol: "calendar",
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

  private func tile(_ title: String, symbol: String, value: String, detail: String,
                    help: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      RingMark(symbol: symbol)
      VStack(alignment: .leading, spacing: 4) {
        Text(value)
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Ink.label(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
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
      RingMark(symbol: "mic.fill")
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
        RingMark(symbol: "flag.checkered")
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
        .fill(Ink.track)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(Ember.horizontal)
            .frame(width: geometry.size.width * progress)
        }
    }
    .frame(height: 6)
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
