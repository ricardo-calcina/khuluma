import Foundation

/// Port of `dictate_lib_apply_vocab_corrections` (bin/dictate-lib.sh):
/// spelled-out acronym compaction, then the global `vocab` rules, then the
/// mode's `vocab` rules, applied in order so earlier rules can feed later ones.
///
/// That Perl runs with `-CS` (character strings), so unlike the other filters
/// it uses Unicode rules: `\s` is `PerlText.unicodeSpaceClass`,
/// `[[:alnum:]]` and `/i` are Unicode-aware. Rule lengths and ties count code
/// points, as Perl's `length`/`cmp` do.
public struct VocabCorrector: Sendable {
  struct Rule: Sendable {
    let left: String
    let right: String
    let pattern: ICURegex
    let template: String
  }

  /// nil when no vocab file exists: the CLI then passes text through
  /// untouched (`cat`), skipping compaction and whitespace tidying too.
  let rules: [Rule]?

  /// Vocab files the CLI would read for `mode`: `<config>/vocab`, then
  /// `<config>/modes/<mode>/vocab`, each only if it is a regular file.
  public static func files(configDir: String, mode: String) -> [String] {
    var files: [String] = []
    let global = configDir + "/vocab"
    if PerlText.isFile(global) { files.append(global) }
    let modeVocab = configDir + "/modes/" + mode + "/vocab"
    if !mode.isEmpty && PerlText.isFile(modeVocab) { files.append(modeVocab) }
    return files
  }

  public init(configDir: String, mode: String) {
    self.init(files: VocabCorrector.files(configDir: configDir, mode: mode))
  }

  public init(files: [String]) {
    guard !files.isEmpty else {
      rules = nil
      return
    }
    var rules: [Rule] = []
    for path in files {
      guard PerlText.isFile(path), let contents = PerlText.readFile(path) else { continue }
      let parsed = PerlText.fileLines(contents).compactMap(VocabCorrector.parseLine)
      // Longest left side first, ties by code point; stable like Perl's sort.
      let sorted = parsed.enumerated().sorted { a, b in
        let la = PerlText.perlLength(a.element.left)
        let lb = PerlText.perlLength(b.element.left)
        if la != lb { return la > lb }
        // Not `!=`: String equality treats canonically equivalent text as equal.
        if !a.element.left.unicodeScalars.elementsEqual(b.element.left.unicodeScalars) {
          return PerlText.codePointLess(a.element.left, b.element.left)
        }
        return a.offset < b.offset
      }
      for entry in sorted {
        guard let pattern = VocabCorrector.rulePattern(entry.element.left) else { continue }
        rules.append(Rule(
          left: entry.element.left, right: entry.element.right, pattern: pattern,
          template: NSRegularExpression.escapedTemplate(for: entry.element.right)))
      }
    }
    self.rules = rules
  }

  public func apply(_ text: String) -> String {
    guard let rules else { return text }
    return PerlText.eachLine(text) { line in
      var out = VocabCorrector.compactSpelledAcronyms(line)
      for rule in rules {
        out = rule.pattern.replaceAll(out, template: rule.template)
      }
      out = VocabCorrector.tabSpaceRun.replaceAll(out, template: " ")
      out = VocabCorrector.leadingTabSpace.replaceAll(out, template: "")
      return VocabCorrector.trailingTabSpace.replaceAll(out, template: "")
    }
  }

  // MARK: Parsing

  private static let s = PerlText.unicodeSpaceClass
  private static let leadingSpace = ICURegex("^\(s)+")
  private static let trailingSpace = ICURegex("\(s)+$")
  private static let colonRule = ICURegex("^(.*?)\(s)*::\(s)*(.*?)$")
  private static let arrowRule = ICURegex("^(.*?)\(s)*(?:\\x{2192}|->)\(s)*(.*?)$")
  private static let partSeparator = ICURegex("\(s)+")

  private static func trim(_ text: String) -> String {
    trailingSpace.replaceFirst(leadingSpace.replaceFirst(text, template: ""), template: "")
  }

  /// One vocab line → (left, right), or nil for blanks, comments and lines
  /// without `::`, `->` or `→`.
  static func parseLine(_ raw: String) -> (left: String, right: String)? {
    let line = trim(raw)
    if line.isEmpty || line.hasPrefix("#") { return nil }
    let ns = line as NSString
    guard let match = colonRule.matches(line).first ?? arrowRule.matches(line).first else { return nil }
    let left = trim(match.group(1, in: ns))
    let right = trim(match.group(2, in: ns))
    if left.isEmpty || right.isEmpty { return nil }
    return (left, right)
  }

  private static func asciiWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122, 95: return true
    default: return false
    }
  }

  /// `build_rule_regex`: words joined by `\s+`, case-insensitive, with
  /// boundaries only on sides that start/end with an ASCII word character.
  static func rulePattern(_ left: String) -> ICURegex? {
    let ns = left as NSString
    var parts: [String] = []
    var cursor = 0
    for match in partSeparator.matches(left) {
      parts.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
      cursor = match.range.location + match.range.length
    }
    parts.append(ns.substring(from: cursor))
    var pattern = parts.filter { !$0.isEmpty }
      .map { NSRegularExpression.escapedPattern(for: $0) }
      .joined(separator: "\(s)+")
    if let first = left.unicodeScalars.first, asciiWordScalar(first) {
      pattern = "(?<![A-Za-z0-9_.-])" + pattern
    }
    if let last = left.unicodeScalars.last, asciiWordScalar(last) {
      pattern += "(?![A-Za-z0-9_.-])"
    }
    return try? ICURegex(validating: pattern, caseInsensitive: true)
  }

  // MARK: Applying

  private static let spelledAcronym = ICURegex(
    "(?<![[:alnum:]_])((?:[A-Za-z](?:[\(s)._-]+)){2,7}[A-Za-z])(?![[:alnum:]_])")
  private static let asciiLetter = ICURegex("[A-Za-z]")
  private static let tabSpaceRun = ICURegex("[ \\t]{2,}")
  private static let leadingTabSpace = ICURegex("^[ \\t]+")
  private static let trailingTabSpace = ICURegex("[ \\t]+$")

  /// "a p i" → "api", "G P T" → "GPT": 3–8 single letters separated by
  /// spaces, dots, underscores or hyphens, if not all the same letter.
  static func compactSpelledAcronyms(_ text: String) -> String {
    spelledAcronym.replaceAll(text) { match, ns in
      let sequence = match.group(1, in: ns)
      let letters = asciiLetter.matches(sequence).map { (sequence as NSString).substring(with: $0.range) }
      let distinct = Set(letters.map { $0.lowercased() })
      guard letters.count >= 3, letters.count <= 8, distinct.count > 1 else { return sequence }
      // Perl lowercases/uppercases the result when the sequence is all one
      // case; the letters already are, so joining them is enough.
      return letters.joined()
    }
  }
}
