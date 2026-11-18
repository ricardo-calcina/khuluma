import KhulumaCore
import SwiftUI

/// The History tab: a search field over the dictations on disk, grouped by
/// day. Rows expand on click; Copy puts the text back on the clipboard.
struct HistoryView: View {
  @ObservedObject var model: HistoryModel

  private var timeFormatter: DateFormatter {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    return fmt
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Search dictations", text: $model.query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
      if model.filtered.isEmpty {
        Spacer()
        Text(model.items.isEmpty ? "No dictations yet."
                                 : "No dictations match “\(model.query)”.")
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.days, id: \.title) { day in
              Ink.label(day.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, day.title == model.days.first?.title ? 2 : 14)
                .padding(.bottom, 6)
              ForEach(day.items) { item in
                row(item)
                Rule()
              }
            }
          }
          .padding(.horizontal, 20)
        }
      }
      Text(model.retentionDays <= 0 ? "Dictations are kept forever."
           : model.retentionDays == 1 ? "Dictations are kept for 1 day."
           : "Dictations are kept for \(model.retentionDays) days.")
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
    .onAppear { model.reload() }
  }

  private func row(_ item: DictationHistory.Item) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(timeFormatter.string(from: item.date)) · \(item.app.isEmpty ? "-" : item.app) · \(WordCount.count(item.text)) words")
          .font(.caption).foregroundStyle(.secondary)
        if !item.delivered {
          Text("Not pasted")
            .font(.caption).foregroundStyle(Ember.accent)
        }
        Spacer(minLength: 8)
        if item.rawDiffers {
          Button(model.showingRaw.contains(item.id) ? "Cleaned" : "Raw") { toggle(&model.showingRaw, item.id) }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Ember.accent)
            .help(model.showingRaw.contains(item.id) ? "Show the cleaned text" : "Show the raw transcript")
        }
        if item.keptWAV != nil, model.transcribeAgain != nil {
          if model.transcribing.contains(item.id) {
            ProgressView().controlSize(.small)
              .accessibilityLabel("Transcribing again")
          } else {
            Button { model.transcribe(item) } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.plain)
              .foregroundStyle(Ember.accent)
              .help("Transcribe again from the kept recording")
              .accessibilityLabel("Transcribe again")
          }
        }
        Button { model.copy(item) } label: {
          Image(systemName: model.copiedID == item.id ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ember.accent)
        .accessibilityLabel("Copy dictation")
      }
      Text(model.showingRaw.contains(item.id) ? item.raw : item.text)
        .font(.callout)
        .foregroundStyle(model.showingRaw.contains(item.id) ? .secondary : .primary)
        .lineLimit(model.expanded.contains(item.id) ? nil : 3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let message = model.rowMessages[item.id] {
        Text(message).font(.caption).foregroundStyle(Ember.accent)
      }
    }
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .onTapGesture { toggle(&model.expanded, item.id) }
  }

  private func toggle(_ set: inout Set<String>, _ id: String) {
    if set.contains(id) { set.remove(id) } else { set.insert(id) }
  }
}
