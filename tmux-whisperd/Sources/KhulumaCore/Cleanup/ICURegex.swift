import Foundation

/// NSRegularExpression (ICU) with Perl-style substitution helpers.
///
/// Every pattern uses Unix line separators, so `^`, `$` and `.` treat only
/// "\n" as a line break, as Perl does (ICU otherwise also breaks on "\r",
/// U+0085, U+2028 and U+2029).
struct ICURegex: @unchecked Sendable {
  // NSRegularExpression is immutable and documented as thread-safe.
  let regex: NSRegularExpression

  init(_ pattern: String, caseInsensitive: Bool = false) {
    // Built-in patterns are constants; a typo should fail loudly in tests.
    // swiftlint:disable:next force_try
    self.regex = try! ICURegex.compile(pattern, caseInsensitive: caseInsensitive)
  }

  init(validating pattern: String, caseInsensitive: Bool = false) throws {
    self.regex = try ICURegex.compile(pattern, caseInsensitive: caseInsensitive)
  }

  private static func compile(_ pattern: String, caseInsensitive: Bool) throws -> NSRegularExpression {
    var options: NSRegularExpression.Options = [.useUnixLineSeparators]
    if caseInsensitive { options.insert(.caseInsensitive) }
    return try NSRegularExpression(pattern: pattern, options: options)
  }

  func matches(_ text: String) -> [NSTextCheckingResult] {
    regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
  }

  func isMatch(_ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
  }

  /// `s/re/template/g`. The template uses ICU syntax (`$1`); pass literal text
  /// through `NSRegularExpression.escapedTemplate(for:)` first.
  func replaceAll(_ text: String, template: String) -> String {
    regex.stringByReplacingMatches(
      in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
  }

  /// `s/re/template/` (first match only).
  func replaceFirst(_ text: String, template: String) -> String {
    let ns = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
      return text
    }
    let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
    return ns.replacingCharacters(in: match.range, with: replacement)
  }

  /// `s/re/expr/ge`: like `replaceAll`, but each replacement is computed.
  func replaceAll(_ text: String, _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
    let ns = text as NSString
    let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !found.isEmpty else { return text }
    let out = NSMutableString()
    var cursor = 0
    for match in found {
      out.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
      out.append(transform(match, ns))
      cursor = match.range.location + match.range.length
    }
    out.append(ns.substring(from: cursor))
    return out as String
  }

  /// `1 while s/re/template/g`.
  func replaceUntilStable(_ text: String, template: String) -> String {
    var current = text
    while isMatch(current) {
      current = replaceAll(current, template: template)
    }
    return current
  }
}

extension NSTextCheckingResult {
  /// Text of capture group `index`, or "" when it did not participate.
  func group(_ index: Int, in text: NSString) -> String {
    let r = range(at: index)
    return r.location == NSNotFound ? "" : text.substring(with: r)
  }
}
