import Foundation

/// Port of the CLI's `merge_transcript_chunks` (Python in bin/khuluma),
/// as used by tail rescue: the full transcript and the re-transcribed tail are
/// written as lines of a file, read back with Python's universal newlines,
/// stripped, and merged on the longest word overlap. Proven against the
/// Python by the `merge` cases in tests/fixtures/cleanup.
public enum TranscriptMerge {
  /// `transcribe_swift_parakeet_tail_rescue_cli`'s merge step: newlines in
  /// the tail become spaces, then both texts are merged.
  ///
  /// The app no longer uses this: when the tail pass differs from the full
  /// transcript by even one word it finds no overlap and appends the whole
  /// tail, repeating it (~25 words at the end of the take). It stays only
  /// for the CLI-parity fixtures and tests that mirror the retired bash CLI;
  /// app code calls `mergeTailAnchored`.
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

  // MARK: - Anchored merge (used by the app)

  /// Merges the re-transcribed tail into the full transcript without ever
  /// repeating text. Tokens are whitespace-split; a token's key is it
  /// lowercased keeping only letters, digits and apostrophes (empty keys
  /// never match but stay in the output). The tail can only extend the full
  /// transcript: anchored on the longest shared run of ≥3 keys inside the
  /// last 80 tokens of `full`, and applied only when the tail then has more
  /// keyed tokens after that run than the full transcript does. Anything
  /// else — no anchor, a diverging or shorter tail — returns `full`
  /// byte-for-byte unchanged.
  public static func mergeTailAnchored(full: String, tail: String) -> String {
    func tokens(_ text: String) -> [String] {
      text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    func key(_ token: String) -> String {
      String(token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }
    let fullTokens = tokens(full)
    let tailTokens = tokens(tail)
    guard !tailTokens.isEmpty else { return full }

    // (token index, key) pairs; F is keyed tokens among full's last 80.
    let fullKeyed = fullTokens.enumerated().compactMap { index, token -> (Int, String)? in
      let k = key(token)
      return k.isEmpty ? nil : (index, k)
    }
    let tailKeyed = tailTokens.enumerated().compactMap { index, token -> (Int, String)? in
      let k = key(token)
      return k.isEmpty ? nil : (index, k)
    }
    let cutoff = max(0, fullTokens.count - 80)
    let f = fullKeyed.filter { $0.0 >= cutoff }
    let t = tailKeyed

    // Longest common contiguous run of keys, length ≥ 3. Ties: the run
    // ending latest in T, then latest in F.
    var anchor: (length: Int, fEnd: Int, tEnd: Int)?
    let limit = min(f.count, t.count)
    if limit >= 3 {
      lengths: for length in stride(from: limit, through: 3, by: -1) {
        for tEnd in stride(from: t.count, through: length, by: -1) {
          let tRun = t[(tEnd - length)..<tEnd].map(\.1)
          for fEnd in stride(from: f.count, through: length, by: -1)
          where f[(fEnd - length)..<fEnd].map(\.1) == tRun {
            anchor = (length, fEnd, tEnd)
            break lengths
          }
        }
      }
    }
    guard let anchor else { return full }

    let fullRest = Array(fullTokens[(f[anchor.fEnd - 1].0 + 1)...])
    let tailRest = Array(tailTokens[(t[anchor.tEnd - 1].0 + 1)...])
    guard tailRest.filter({ !key($0).isEmpty }).count > fullRest.filter({ !key($0).isEmpty }).count else {
      return full
    }
    return (fullTokens[...f[anchor.fEnd - 1].0] + tailRest).joined(separator: " ")
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
