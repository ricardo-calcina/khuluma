import Foundation

/// Time actually spent speaking in a take, from its word spans. Only for
/// reporting: nothing here touches the audio sent for transcription.
public enum SpeechTime {
  /// Gaps between words longer than this are pauses and are left out.
  public static let pauseThresholdMs = 1000

  /// Sum of the word spans plus every gap between consecutive words of at
  /// most `pauseThresholdMs`. Silence before the first word and after the
  /// last is left out. Invalid spans (negative, end before start) are
  /// dropped; overlapping spans merge. Nil when there are no valid spans.
  public static func speechMs(spans: [[Int]], pauseThresholdMs: Int = pauseThresholdMs) -> Int? {
    speechMs(pairs: spans.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, pauseThresholdMs: pauseThresholdMs)
  }

  public static func speechMs(pairs: [(Int, Int)], pauseThresholdMs: Int = pauseThresholdMs) -> Int? {
    let valid = pairs.filter { $0.0 >= 0 && $0.1 >= $0.0 }.sorted { $0.0 < $1.0 }
    guard var current = valid.first else { return nil }
    var total = 0
    for span in valid.dropFirst() {
      if span.0 <= current.1 {
        current.1 = max(current.1, span.1)
        continue
      }
      total += current.1 - current.0
      let gap = span.0 - current.1
      if gap <= pauseThresholdMs { total += gap }
      current = span
    }
    return total + (current.1 - current.0)
  }
}
