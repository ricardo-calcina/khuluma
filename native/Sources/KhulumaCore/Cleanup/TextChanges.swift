import Foundation

/// What cleanup changed, word by word, for the vocabulary editor's preview:
/// each run of words that differs between the input and the result.
public struct TextChange: Equatable, Hashable, Sendable {
  /// "" when words were added.
  public var before: String
  /// "" when words were removed.
  public var after: String
  public init(before: String, after: String) { self.before = before; self.after = after }

  /// Longest common subsequence over whitespace-separated words. Longer
  /// texts (beyond `limit` words on either side) report nothing rather than
  /// stall the editor.
  public static func between(_ input: String, _ output: String, limit: Int = 3000) -> [TextChange] {
    let a = input.split(whereSeparator: \.isWhitespace).map(String.init)
    let b = output.split(whereSeparator: \.isWhitespace).map(String.init)
    guard a.count <= limit, b.count <= limit else { return [] }
    // lengths[i][j]: LCS of a[i...] and b[j...].
    var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
      }
    }
    var changes: [TextChange] = []
    var removed: [String] = [], added: [String] = []
    func flush() {
      if !removed.isEmpty || !added.isEmpty {
        changes.append(TextChange(before: removed.joined(separator: " "), after: added.joined(separator: " ")))
      }
      removed = []; added = []
    }
    var i = 0, j = 0
    while i < a.count || j < b.count {
      if i < a.count, j < b.count, a[i] == b[j] {
        flush(); i += 1; j += 1
      } else if j < b.count, i == a.count || lengths[i][j + 1] >= lengths[i + 1][j] {
        added.append(b[j]); j += 1
      } else {
        removed.append(a[i]); i += 1
      }
    }
    flush()
    return changes
  }

  /// A rule that would turn `got` into `expected` when they differ in one
  /// run of words, ignoring punctuation at its edges ("kaluma." → "Khuluma.").
  /// Nil for anything a single literal replacement can't explain.
  public static func suggestedRule(got: String, expected: String) -> VocabularySheet.Correction? {
    let changes = between(got, expected)
    guard changes.count == 1 else { return nil }
    var heard = changes[0].before, write = changes[0].after
    let edges = CharacterSet.punctuationCharacters
    while let a = heard.unicodeScalars.last, let b = write.unicodeScalars.last, a == b, edges.contains(a) {
      heard.unicodeScalars.removeLast(); write.unicodeScalars.removeLast()
    }
    while let a = heard.unicodeScalars.first, let b = write.unicodeScalars.first, a == b, edges.contains(a) {
      heard.unicodeScalars.removeFirst(); write.unicodeScalars.removeFirst()
    }
    guard !heard.isEmpty, !write.isEmpty else { return nil }
    return VocabularySheet.Correction(heard: heard, write: write)
  }
}
