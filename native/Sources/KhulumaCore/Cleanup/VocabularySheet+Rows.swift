import Foundation

/// The editor's view of a sheet: one section at a time, as rows keyed by
/// their heard (or said) text.
extension VocabularySheet {
  public enum Section: String, CaseIterable, Identifiable, Sendable {
    case fillers = "Fillers", brands = "Brands", words = "Other words", examples = "Examples"
    public var id: String { rawValue }
  }

  /// Heard text identifies a row; fillers leave `write` empty.
  public struct Row: Identifiable, Hashable, Sendable {
    public var heard: String
    public var write: String
    public var id: String { heard }
    public init(heard: String, write: String = "") { self.heard = heard; self.write = write }
  }

  public func rows(_ section: Section) -> [Row] {
    switch section {
    case .fillers: return fillers.map { Row(heard: $0) }
    case .brands: return brands.map { Row(heard: $0.heard, write: $0.write) }
    case .words: return words.map { Row(heard: $0.heard, write: $0.write) }
    case .examples: return (examples ?? []).map { Row(heard: $0.said, write: $0.expect) }
    }
  }

  /// Replaces the row `original` names in place, or appends. An example with
  /// Said text already present replaces that example. Not validated.
  public func upserting(_ row: Row, in section: Section, replacing original: String?) -> Self {
    var next = self
    let correction = Correction(heard: row.heard, write: row.write)
    func put<T>(_ list: inout [T], _ value: T, at index: Int?) {
      if let index { list[index] = value } else { list.append(value) }
    }
    switch section {
    case .fillers: put(&next.fillers, row.heard, at: next.fillers.firstIndex { $0 == original })
    case .brands: put(&next.brands, correction, at: next.brands.firstIndex { $0.heard == original })
    case .words: put(&next.words, correction, at: next.words.firstIndex { $0.heard == original })
    case .examples:
      var examples = next.examples ?? []
      let key = original ?? row.heard
      put(&examples, Example(said: row.heard, expect: row.write), at: examples.firstIndex { $0.said == key })
      next.examples = examples
    }
    return next
  }

  public func removing(_ ids: Set<String>, from section: Section) -> Self {
    var next = self
    switch section {
    case .fillers: next.fillers.removeAll { ids.contains($0) }
    case .brands: next.brands.removeAll { ids.contains($0.heard) }
    case .words: next.words.removeAll { ids.contains($0.heard) }
    case .examples: next.examples?.removeAll { ids.contains($0.said) }
    }
    return next
  }

  /// After removing `ids`, the row a list selects next: the first one that
  /// followed the removed rows, else the one before them.
  public static func selectionAfterRemoving(_ ids: Set<String>, from rows: [Row]) -> String? {
    guard let first = rows.firstIndex(where: { ids.contains($0.id) }) else { return nil }
    return rows[first...].first { !ids.contains($0.id) }?.id ?? rows[..<first].last?.id
  }
}
