import Foundation

/// Ports of the CLI's Perl cleanup filters in bin/dictate-lib.sh. Each
/// function returns exactly what the Perl one-liner prints for the same input
/// (callers apply bash's `$(...)` newline stripping between stages).
///
/// These filters run Perl without `-CS`, so they see UTF-8 bytes: `\s`, `\b`
/// and `/i` are ASCII-only. They run under `PerlText.byteMode` and spell `\s`
/// out as `PerlText.asciiSpaceClass`.
public enum TextCleanup {
  private static let s = PerlText.asciiSpaceClass

  // MARK: dictate_lib_sanitize_transcript_artifacts

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

  // MARK: dictate_lib_clean_fillers

  private static let fillerRules: [(ICURegex, String)] = [
    (ICURegex("\\b(um|uh|uhh|umm|er|err|ah|ahh|hmm|hm|mhm|erm|huh)\\b[,.]?\(s)*", caseInsensitive: true), ""),
    (ICURegex(
      "\\b(you know|I mean|kind of|sort of|basically|actually|literally|obviously|honestly|frankly|clearly),?\(s)*",
      caseInsensitive: true), ""),
    (ICURegex(
      "\\b(I guess|I think|I suppose|I believe|in my opinion|to be honest|to be fair),?\(s)*",
      caseInsensitive: true), ""),
    (ICURegex(
      "\\b(so yeah|and yeah|but yeah|yeah so|ok so|okay so|alright so|right so),?\(s)*",
      caseInsensitive: true), ""),
    (ICURegex("\\b(anyway|anyways|anyhow),?\(s)*", caseInsensitive: true), ""),
    (ICURegex("\\b(like),?\(s)+(like),?", caseInsensitive: true), "like"),
    (ICURegex("\(s)+"), " "),
  ]
  private static let fillerTidy: [(ICURegex, String)] = [
    (ICURegex(" ,"), ","),
    (ICURegex(" \\."), "."),
    (ICURegex(",,"), ","),
  ]
  private static let leadingSpace = ICURegex("^ ")
  private static let trailingSpace = ICURegex(" $")

  /// Removes filler words and hedges. Like the Perl, it also folds each line
  /// break into the following text (`a\nb` becomes `ab`).
  public static func cleanFillers(_ text: String) -> String {
    PerlText.byteMode(text) { bytes in
      PerlText.eachLine(bytes) { line in
        var out = line
        for (rule, template) in fillerRules {
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

  // MARK: dictate_lib_clean_repeats

  private static let word = "[A-Za-z]+(?:'[A-Za-z]+)*"
  private static let repeatedTriple = ICURegex(
    "\\b(\(word))\(s)+(\(word))\(s)+(\(word))\\b\(s)+\\1\(s)+\\2\(s)+\\3\\b", caseInsensitive: true)
  private static let repeatedPair = ICURegex(
    "\\b(\(word))\(s)+(\(word))\\b\(s)+\\1\(s)+\\2\\b", caseInsensitive: true)
  private static let repeatedWord = ICURegex("\\b(\(word))\\b\(s)+\\1\\b", caseInsensitive: true)
  private static let anySpaceRun = ICURegex("\(s)+")

  /// Collapses stutters. `level` is Perl's `int()` of the configured level:
  /// >= 2 also collapses repeated 2–3 word phrases, >= 1 repeated words.
  /// Whitespace is normalised at every level, as in the Perl.
  public static func cleanRepeats(_ text: String, level: Double) -> String {
    PerlText.byteMode(text) { bytes in
      PerlText.eachLine(bytes) { line in
        var out = line
        if level >= 2 {
          out = repeatedTriple.replaceUntilStable(out, template: "$1 $2 $3")
          out = repeatedPair.replaceUntilStable(out, template: "$1 $2")
        }
        if level >= 1 {
          out = repeatedWord.replaceUntilStable(out, template: "$1")
        }
        out = anySpaceRun.replaceAll(out, template: " ")
        out = leadingSpace.replaceFirst(out, template: "")
        return trailingSpace.replaceFirst(out, template: "")
      }
    }
  }

  // MARK: dictate_lib_normalize_british_spelling

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
