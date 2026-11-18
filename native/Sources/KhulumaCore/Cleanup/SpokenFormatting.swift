import Foundation

/// Spoken "new line" / "newline" / "new paragraph" turned into line breaks.
/// Runs on the cleaned text after `TextPipeline`, never inside it (that
/// pipeline is parity-tested against the CLI).
///
/// A phrase is a command only when a boundary comes before it: start of
/// text, sentence punctuation (. ! ? : ; ,) or a line break, whatever
/// follows. So "I drew a new line." stays speech. The command goes with its adjoining spaces, the
/// punctuation after it and a comma before it; a full stop or other sentence
/// mark before it stays. The first letter after a break is capitalised.
/// Breaks at the very start or end are dropped, 3+ breaks collapse to 2.
public enum SpokenFormatting {
  private static let command = try! NSRegularExpression(
    pattern: #"\b(?:new[ \t]+paragraph|new[ \t]*line)\b"#, options: [.caseInsensitive])
  private static let marks = Set(".!?:;,")

  public static func apply(_ text: String) -> String {
    let ns = text as NSString
    let matches = command.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }
    let chars = Array(text.utf16)
    func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 }
    func isMark(_ u: UInt16) -> Bool { u < 128 && marks.contains(Character(UnicodeScalar(UInt8(u)))) }

    var out = ""
    var cursor = 0
    var changed = false
    var capitaliseNext = false
    func append(_ piece: String) {
      guard !piece.isEmpty else { return }
      if capitaliseNext, let first = piece.first, first.isLetter {
        out += first.uppercased() + piece.dropFirst()
        capitaliseNext = false
      } else {
        out += piece
        if piece.contains(where: { !$0.isWhitespace }) { capitaliseNext = false }
      }
    }
    for m in matches {
      let start = m.range.location, end = start + m.range.length
      guard start >= cursor else { continue }
      var before = start - 1
      while before >= 0, isSpace(chars[before]) { before -= 1 }
      guard before < 0 || isMark(chars[before]) || chars[before] == 10 else { continue }
      append(ns.substring(with: NSRange(location: cursor, length: start - cursor)))
      // Trim what came before: spaces, then a comma (sentence marks stay).
      while let last = out.last, last == " " || last == "\t" { out.removeLast() }
      if out.last == "," { out.removeLast() }
      while let last = out.last, last == " " || last == "\t" { out.removeLast() }
      let paragraph = ns.substring(with: m.range).lowercased().hasSuffix("paragraph")
      out += paragraph ? "\n\n" : "\n"
      // Skip spaces and punctuation after it.
      var next = end
      while next < chars.count, isSpace(chars[next]) || isMark(chars[next]) { next += 1 }
      cursor = next
      capitaliseNext = true
      changed = true
    }
    guard changed else { return text }
    append(ns.substring(from: cursor))
    out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    while out.first == "\n" { out.removeFirst() }
    while let last = out.last, last == "\n" || last == " " { out.removeLast() }
    return out.isEmpty ? text : out
  }
}
