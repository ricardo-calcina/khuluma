import Foundation

/// Ports of the CLI's Perl cleanup filters in bin/khuluma-lib.sh. Each
/// function returns exactly what the Perl one-liner prints for the same input
/// (callers apply bash's `$(...)` newline stripping between stages).
///
/// These filters run Perl without `-CS`, so they see UTF-8 bytes: `\s`, `\b`
/// and `/i` are ASCII-only. They run under `PerlText.byteMode` and spell `\s`
/// out as `PerlText.asciiSpaceClass`.
public enum TextCleanup {
  private static let s = PerlText.asciiSpaceClass

  // MARK: khuluma_lib_sanitize_transcript_artifacts

  private static let blankAudio = "blank(?:\(s)*[_-]\(s)*|\(s)+)audio"
  private static let sanitizeRules: [(ICURegex, String)] = [
    (ICURegex("\\[\(s)*\(blankAudio)\(s)*\\]", caseInsensitive: true), ""),
    (ICURegex("\\(\(s)*\(blankAudio)\(s)*\\)", caseInsensitive: true), ""),
    (ICURegex("\\{\(s)*\(blankAudio)\(s)*\\}", caseInsensitive: true), ""),
    (ICURegex("\(s)+([,.;:!?])"), "$1"),
    (ICURegex("([(\\[{])\(s)+"), "$1"),
    (ICURegex("\(s)+([)\\]}])"), "$1"),
    (ICURegex("[ \\t]{2,}"), " "),
  ]
  private static let leadingSpaces = ICURegex("^ +")
  private static let trailingSpaces = ICURegex(" +$")

  /// Removes `[blank audio]`-style placeholders and tidies punctuation spacing.
  public static func sanitizeArtifacts(_ text: String) -> String {
    PerlText.byteMode(text) { bytes in
      PerlText.eachLine(bytes) { line in
        var out = line
        for (rule, template) in sanitizeRules {
          out = rule.replaceAll(out, template: template)
        }
        out = leadingSpaces.replaceFirst(out, template: "")
        return trailingSpaces.replaceFirst(out, template: "")
      }
    }
  }

  // MARK: khuluma_lib_clean_fillers

  private static let fillerRules: [(ICURegex, String)] = [
    (ICURegex(
      #"(?<![\w./@'"`-])\b(?:um+|uh+|erm)\b(?![\w/@'"`-]|\.[A-Za-z0-9])[,.]?"# + "\(s)*",
      caseInsensitive: true), ""),
    (ICURegex("\(s)+"), " "),
  ]
  private static let fillerTidy: [(ICURegex, String)] = [
    (ICURegex(" ,"), ","),
    (ICURegex(" \\."), "."),
    (ICURegex(",,"), ","),
  ]
  private static let leadingSpace = ICURegex("^ ")
  private static let trailingSpace = ICURegex(" $")

  /// Removes hesitation sounds, preserving hedges and quoted words.
  /// Like the Perl, it also folds each line
  /// break into the following text (`a\nb` becomes `ab`).
  public static func cleanFillers(_ text: String, words: [String]? = nil) -> String {
    var rules = fillerRules
    if let words {
      let phrases = words.sorted { $0.utf8.count > $1.utf8.count }.map {
        NSRegularExpression.escapedPattern(for: PerlText.byteView($0.utf8))
      }
      let pattern = phrases.isEmpty ? "(?!)" : phrases.joined(separator: "|")
      rules[0] = (ICURegex(
        #"(?<![\w./@'"`-])(?:"# + pattern + #")(?![\w/@'"`-]|\.[A-Za-z0-9])[,.]?"# + "\(s)*",
        caseInsensitive: true), "")
    }
    return PerlText.byteMode(text) { bytes in
      PerlText.eachLine(bytes) { line in
        var out = line
        for (rule, template) in rules {
          out = rule.replaceAll(out, template: template)
        }
        out = leadingSpace.replaceFirst(out, template: "")
        out = trailingSpace.replaceFirst(out, template: "")
        for (rule, template) in fillerTidy {
          out = rule.replaceAll(out, template: template)
        }
        return out
      }
    }
  }

  // MARK: khuluma_lib_clean_repeats

  private static let word = "[A-Za-z]+(?:'[A-Za-z]+)*"
  private static let repeatedTriple = ICURegex(
    "\\b(\(word))\(s)+(\(word))\(s)+(\(word))\\b\(s)+\\1\(s)+\\2\(s)+\\3\\b", caseInsensitive: true)
  private static let repeatedPair = ICURegex(
    "\\b(\(word))\(s)+(\(word))\\b\(s)+\\1\(s)+\\2\\b", caseInsensitive: true)
  private static let repeatedWord = ICURegex("\\b(\(word))\\b\(s)+\\1\\b", caseInsensitive: true)
  private static let anySpaceRun = ICURegex("\(s)+")
  private static let repeatedSentence = ICURegex(
    "(^|[.!?] +)([A-Za-z0-9][^.!?\\r\\n]{0,2000}[.!?]) +\\2(?=\(s)|$)", caseInsensitive: true)
  private static let sentenceWord = ICURegex("[A-Za-z0-9]+(?:'[A-Za-z0-9]+)*")

  private static func cleanRepeatedSentences(_ text: String) -> String {
    var out = text
    while true {
      let next = repeatedSentence.replaceAll(out) { match, ns in
        let sentence = match.group(2, in: ns)
        guard sentenceWord.matches(sentence).count >= 5 else { return match.group(0, in: ns) }
        return match.group(1, in: ns) + sentence
      }
      if next == out { return out }
      out = next
    }
  }

  /// Collapses stutters. `level` is Perl's `int()` of the configured level:
  /// Level 2 collapses repeated 2–3 word phrases and words, level 1 words.
  /// >= 3 only collapses exact adjacent sentences of at least five words,
  /// preserving short emphasis and grammatical doubles such as "had had".
  /// Whitespace is normalised at every level, as in the Perl.
  public static func cleanRepeats(_ text: String, level: Double) -> String {
    PerlText.byteMode(text) { bytes in
      PerlText.eachLine(bytes) { line in
        var out = line
        if level >= 3 {
          out = cleanRepeatedSentences(anySpaceRun.replaceAll(out, template: " "))
        }
        if level >= 2 && level < 3 {
          out = repeatedTriple.replaceUntilStable(out, template: "$1 $2 $3")
          out = repeatedPair.replaceUntilStable(out, template: "$1 $2")
        }
        if level >= 1 && level < 3 {
          out = repeatedWord.replaceUntilStable(out, template: "$1")
        }
        out = anySpaceRun.replaceAll(out, template: " ")
        out = leadingSpace.replaceFirst(out, template: "")
        return trailingSpace.replaceFirst(out, template: "")
      }
    }
  }

  // MARK: khuluma_lib_normalize_british_spelling

  static let britishSpellings: [String: String] = [
    "color": "colour", "colors": "colours", "colored": "coloured", "coloring": "colouring",
    "favorite": "favourite", "favorites": "favourites", "favorited": "favourited", "favoriting": "favouriting",
    "organize": "organise", "organizes": "organises", "organized": "organised", "organizing": "organising",
    "organization": "organisation", "organizations": "organisations",
    "optimize": "optimise", "optimizes": "optimises", "optimized": "optimised", "optimizing": "optimising",
    "optimization": "optimisation", "optimizations": "optimisations",
    "optimizer": "optimiser", "optimizers": "optimisers",
    "prioritize": "prioritise", "prioritizes": "prioritises", "prioritized": "prioritised",
    "prioritizing": "prioritising",
    "prioritization": "prioritisation", "prioritizations": "prioritisations",
    "behavior": "behaviour", "behaviors": "behaviours", "behavioral": "behavioural",
    "center": "centre", "centers": "centres", "centered": "centred", "centering": "centring",
    "centralize": "centralise", "centralizes": "centralises", "centralized": "centralised",
    "centralizing": "centralising",
    "centralization": "centralisation", "centralizations": "centralisations",
    "analyze": "analyse", "analyzes": "analyses", "analyzed": "analysed", "analyzing": "analysing",
    "analyzer": "analyser", "analyzers": "analysers",
    "realize": "realise", "realizes": "realises", "realized": "realised", "realizing": "realising",
  ]

  private static let britishPattern: ICURegex = {
    // Longest first, as in the Perl. Equal-length words can never both match
    // at one position, so their relative order does not matter.
    let words = britishSpellings.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    return ICURegex("\\b(\(words.joined(separator: "|")))\\b", caseInsensitive: true)
  }()
  private static let titleCaseWord = ICURegex("^[A-Z][a-z]+$")

  /// US → UK spellings for a fixed word list, keeping ALL CAPS / Title case.
  /// `enabled` is the raw setting: "0", "off", "false" or "no" disable it.
  public static func normalizeBritishSpelling(_ text: String, enabled: String = "1") -> String {
    guard isBritishSpellingEnabled(enabled) else { return text }
    return PerlText.byteMode(text) { bytes in
      PerlText.eachLine(bytes) { line in
        britishPattern.replaceAll(line) { match, ns in
          let original = match.group(1, in: ns)
          let replacement = britishSpellings[original.lowercased()] ?? original
          if original == original.uppercased() { return replacement.uppercased() }
          if titleCaseWord.isMatch(original) { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
          return replacement
        }
      }
    }
  }

  static func isBritishSpellingEnabled(_ raw: String) -> Bool {
    let value = raw.isEmpty ? "1" : raw
    return !["0", "off", "false", "no"].contains(PerlText.asciiLowercased(value))
  }
}
