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
}
