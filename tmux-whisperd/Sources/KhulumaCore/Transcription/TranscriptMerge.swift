import Foundation

/// Port of the CLI's `merge_transcript_chunks` (Python in bin/tmux-whisper),
/// as used by tail rescue: the full transcript and the re-transcribed tail are
/// written as lines of a file, read back with Python's universal newlines,
/// stripped, and merged on the longest word overlap. Proven against the
/// Python by the `merge` cases in tests/fixtures/cleanup.
public enum TranscriptMerge {
  /// `transcribe_swift_parakeet_tail_rescue_cli`'s merge step: newlines in
  /// the tail become spaces, then both texts are merged.
  public static func mergeTailRescue(full: String, tail: String) -> String {
    let tailLine = String(String.UnicodeScalarView(tail.unicodeScalars.map { $0 == "\n" ? " " : $0 }))
    let file = full + "\n" + tailLine + "\n"
    return merge(lines: pythonLines(file))
  }

  /// The merge loop over already-split lines.
  static func merge(lines rawLines: [String]) -> String {
    let texts = rawLines.map(pythonStrip).filter { !$0.isEmpty }
    var merged: [Unicode.Scalar] = []
    var mergedWords: [String] = []

    for textString in texts {
      let text = Array(textString.unicodeScalars)
      if merged.isEmpty {
        merged = text
        mergedWords = normWords(merged)
        continue
      }
      let incoming = normWords(text)
      var incomingOffset = 0
      var overlap = 0
      let maxOverlap = min(24, mergedWords.count, incoming.count)
      if maxOverlap >= 2 {
        for size in stride(from: maxOverlap, to: 1, by: -1)
        where Array(mergedWords.suffix(size)) == Array(incoming.prefix(size)) {
          overlap = size
          break
        }
      }
      if overlap == 0 {
        let maxOffset = min(12, max(0, incoming.count - 2))
        if maxOffset >= 1 {
          offsets: for offset in 1...maxOffset {
            let limit = min(24, mergedWords.count, incoming.count - offset)
            guard limit >= 2 else { continue }
            for size in stride(from: limit, to: 1, by: -1)
            where Array(mergedWords.suffix(size)) == Array(incoming[offset..<(offset + size)]) {
              incomingOffset = offset
              overlap = size
              break offsets
            }
          }
        }
      }

      if overlap > 0 {
        let cut = charAfterWords(text, incomingOffset + overlap)
        let rest = lstrip(Array(text[cut...]), chars: Set(" \t,.;:!?-".unicodeScalars))
        if !rest.isEmpty {
          merged = pythonStrip(rstripWhitespace(merged) + [" "] + rest)
        }
      } else {
        merged = pythonStrip(rstripWhitespace(merged) + [" "] + lstripWhitespace(text))
      }
      mergedWords = normWords(merged)
    }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: merged)
    return String(view)
  }

  // MARK: Python semantics

  /// `str.isspace()` (Unicode White_Space plus the ASCII separators).
  static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
      return true
    default:
      return false
    }
  }

  /// Iterating a text-mode file with universal newlines: "\n", "\r\n" and
  /// "\r" end a line. Line contents are returned without terminators.
  static func pythonLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var pending = false
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\n" || scalar == "\r" {
        lines.append(String(current))
        current = String.UnicodeScalarView()
        pending = false
        if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
      } else {
        current.append(scalar)
        pending = true
      }
      index += 1
    }
    if pending { lines.append(String(current)) }
    return lines
  }

  static func pythonStrip(_ text: String) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: pythonStrip(Array(text.unicodeScalars)))
    return String(view)
  }

  private static func pythonStrip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    rstripWhitespace(lstripWhitespace(scalars))
  }

  private static func lstripWhitespace(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    Array(scalars.drop(while: isPythonSpace))
  }

  private static func rstripWhitespace(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var end = scalars.count
    while end > 0 && isPythonSpace(scalars[end - 1]) { end -= 1 }
    return Array(scalars[..<end])
  }

  private static func lstrip(_ scalars: [Unicode.Scalar], chars: Set<Unicode.Scalar>) -> [Unicode.Scalar] {
    Array(scalars.drop(while: { chars.contains($0) }))
  }

  /// `re.finditer(r"[A-Za-z0-9']+", text)`: ASCII-only word runs, as
  /// (start, end) scalar offsets.
  private static func wordRanges(_ text: [Unicode.Scalar]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start: Int?
    for (index, scalar) in text.enumerated() {
      let isWord: Bool
      switch scalar.value {
      case 48...57, 65...90, 97...122, 39: isWord = true
      default: isWord = false
      }
      if isWord {
        if start == nil { start = index }
      } else if let begin = start {
        ranges.append(begin..<index)
        start = nil
      }
    }
    if let begin = start { ranges.append(begin..<text.count) }
    return ranges
  }

  private static func normWords(_ text: [Unicode.Scalar]) -> [String] {
    wordRanges(text).map { range in
      var view = String.UnicodeScalarView()
      for scalar in text[range] {
        view.append(scalar.value >= 65 && scalar.value <= 90 ? Unicode.Scalar(scalar.value + 32)! : scalar)
      }
      return String(view)
    }
  }

  /// Index just after the `count`-th word, or 0 when out of range.
  private static func charAfterWords(_ text: [Unicode.Scalar], _ count: Int) -> Int {
    let ranges = wordRanges(text)
    guard count > 0, count <= ranges.count else { return 0 }
    return ranges[count - 1].upperBound
  }
}
