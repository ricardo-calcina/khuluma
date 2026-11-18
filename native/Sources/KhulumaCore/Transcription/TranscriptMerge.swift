import Foundation

/// Merges the tail pass of a long take into its full transcript.
public enum TranscriptMerge {
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
}
