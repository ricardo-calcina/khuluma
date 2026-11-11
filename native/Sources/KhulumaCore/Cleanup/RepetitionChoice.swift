/// The two Settings controls and the one stored level behind them.
/// `clean.repeats_level` is one exclusive choice 0–5; the UI splits it into
/// "Repeated sentences" (levels 3–5) and "Repeated words" (keep / single
/// words / words and short phrases). Levels 0–3 are the bash CLI's
/// exclusive choices; 4 and 5 combine sentences with words.
public struct RepetitionChoice: Equatable, Sendable {
  public var sentences: Bool
  public var words: Words

  public enum Words: String, CaseIterable, Sendable {
    /// Repeated words are left as said.
    case keep
    /// Collapse repeated single words.
    case words
    /// Collapse repeated single words and 2–3 word phrases.
    case phrases
  }

  public init(level: String) {
    switch level {
    case "1": sentences = false; words = .words
    case "2": sentences = false; words = .phrases
    case "3": sentences = true;  words = .keep
    case "4": sentences = true;  words = .words
    case "5": sentences = true;  words = .phrases
    default:  sentences = false; words = .keep
    }
  }

  public var level: String {
    switch (sentences, words) {
    case (false, .keep):    "0"
    case (false, .words):   "1"
    case (false, .phrases): "2"
    case (true,  .keep):    "3"
    case (true,  .words):   "4"
    case (true,  .phrases): "5"
    }
  }
}
