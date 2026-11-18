import Foundation

/// Joins the per-segment transcripts of "transcribe while recording" into
/// the take's single text and word timings.
public enum LiveTranscript {
  public struct Part: Equatable, Sendable {
    public var text: String
    public var wordSpansMs: [[Int]]?
    /// Where the segment starts in the take, for shifting its spans.
    public var startMs: Int
    public init(text: String, wordSpansMs: [[Int]]? = nil, startMs: Int) {
      self.text = text
      self.wordSpansMs = wordSpansMs
      self.startMs = startMs
    }
  }

  /// Texts trimmed and joined with one space, empty parts skipped. Spans
  /// shifted by each part's startMs and concatenated; nil if any non-empty
  /// part has nil spans.
  public static func join(_ parts: [Part]) -> (text: String, wordSpansMs: [[Int]]?) {
    var texts: [String] = []
    var spans: [[Int]] = []
    var spansKnown = true
    for part in parts {
      let text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      texts.append(text)
      guard let partSpans = part.wordSpansMs else {
        spansKnown = false
        continue
      }
      for span in partSpans where span.count >= 2 {
        spans.append([span[0] + part.startMs, span[1] + part.startMs])
      }
    }
    return (texts.joined(separator: " "), spansKnown ? spans : nil)
  }

  /// The pass at stop over the still-open tail. Transcribed on its own, a
  /// short tail that starts mid-sentence (or is only trailing silence) lets
  /// Parakeet invent an ending: "amount" came back "amount of the same",
  /// and half a second of silence "yeah" or "mmhmm" (3 of 24 takes,
  /// 17-18 Nov 2026; the whole file and any 15 s+ window ended right). So
  /// the pass starts earlier, inside already-transcribed audio, and its
  /// text is merged onto the prefix at the words they share.
  public enum FinalPass {
    /// The window is at least this long, when the take allows it.
    public static let minWindowMs = 15_000
    /// And always reaches at least this far back, to anchor the merge.
    public static let minContextMs = 4_000

    /// Where the final pass starts: at most `coveredSamples` (the last cut),
    /// never before 0.
    public static func windowStart(coveredSamples: Int, totalSamples: Int,
                                   sampleRate: Int = AudioPrep.sampleRate) -> Int {
      let tail = max(0, totalSamples - coveredSamples)
      let context = max(minContextMs * sampleRate / 1000, minWindowMs * sampleRate / 1000 - tail)
      return max(0, coveredSamples - context)
    }

    /// The prefix text extended by the window's words after the cut; the
    /// prefix unchanged when the window adds nothing (trailing silence).
    /// nil when the two don't line up clearly: the caller transcribes the
    /// tail alone.
    ///
    /// The anchor is the longest run (uncapped, so a long repeat can't tie
    /// with the true overlap) of ≥3 words (keys: lowercased letters,
    /// digits, apostrophes) that ends at the prefix's end, or up to
    /// `maxSlack` words before it (the window may hear the last words
    /// differently). Ties take the earliest run in the window: the context
    /// comes first, so a phrase repeated in the new speech can't be mistaken
    /// for it. The prefix words after the anchor are replaced by the
    /// window's only when the window has at least as many there.
    public static func merge(prefix: String, window: String) -> String? {
      func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      }
      func key(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
      }
      let prefixTokens = tokens(prefix)
      let windowTokens = tokens(window)
      let p = prefixTokens.indices.compactMap { i -> (Int, String)? in
        let k = key(prefixTokens[i]); return k.isEmpty ? nil : (i, k)
      }
      let w = windowTokens.indices.compactMap { i -> (Int, String)? in
        let k = key(windowTokens[i]); return k.isEmpty ? nil : (i, k)
      }
      guard p.count >= 3, w.count >= 3 else { return nil }

      // (run length, prefix slack, keyed index in w where the run ends).
      var best: (length: Int, slack: Int, wEnd: Int)?
      for slack in 0...min(maxSlack, p.count - 3) {
        let pEnd = p.count - slack
        for wEnd in 1...w.count {
          var length = 0
          while length < min(pEnd, wEnd), p[pEnd - 1 - length].1 == w[wEnd - 1 - length].1 {
            length += 1
          }
          guard length >= 3 else { continue }
          if let current = best,
             length < current.length || (length == current.length && slack >= current.slack) {
            continue
          }
          best = (length, slack, wEnd)
        }
      }
      guard let best else { return nil }
      let prefixCut = p[p.count - best.slack - 1].0
      let windowCut = w[best.wEnd - 1].0
      let windowRest = windowTokens[(windowCut + 1)...]
      guard windowRest.filter({ !key($0).isEmpty }).count >= best.slack else { return nil }
      if best.slack == 0 && windowRest.allSatisfy({ key($0).isEmpty }) { return prefix }
      return (prefixTokens[...prefixCut] + windowRest).joined(separator: " ")
    }

    /// Prefix words after the anchor the window may re-hear.
    static let maxSlack = 3  }
}
