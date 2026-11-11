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
      Text(model.retentionDays == 1
           ? "Dictations are kept for 1 day."
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
        Button { model.copy(item) } label: {
          Image(systemName: model.copiedID == item.id ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ember.accent)
        .accessibilityLabel("Copy dictation")
      }
      Text(item.text)
        .font(.callout)
        .lineLimit(model.expanded.contains(item.id) ? nil : 3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .onTapGesture {
      if model.expanded.contains(item.id) { model.expanded.remove(item.id) }
      else { model.expanded.insert(item.id) }
    }
  }
}
