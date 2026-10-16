import Foundation

/// Helpers that reproduce how the CLI's bash + Perl cleanup sees text, so the
/// Swift port can match it byte for byte.
enum PerlText {
  /// Perl's `\s` on byte strings (the default without `-CS`): ASCII only,
  /// including vertical tab. Also bash's `[[:space:]]` in the C locale.
  static let asciiSpaceClass = "[ \\t\\n\\r\\f\\x{0B}]"

  /// Perl's `\s` on character strings (`-CS`, Unicode rules). ICU's `\s` is
  /// different: it lacks U+000B and U+0085.
  static let unicodeSpaceClass =
    "[\\t\\n\\x{0B}\\f\\r \\x{85}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}]"

  static let asciiSpaces: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0C}", "\u{0B}"]

  // MARK: Byte mode

  private static let byteBase: UInt32 = 0xF700

  /// Runs `body` on a byte-faithful view of `text`, the way Perl sees input
  /// when it is not decoded (`perl -pe` without `-CS`).
  ///
  /// Each UTF-8 byte >= 0x80 becomes its own private-use scalar
  /// (U+F780...U+F7FF). Those never count as word characters or whitespace
  /// and never case-fold, so ICU matches exactly what Perl's byte semantics
  /// match: ASCII-only `\w`, `\b` and `/i`. Without this, ICU would treat
  /// e.g. U+212A KELVIN SIGN as a case variant of "k".
  static func byteMode(_ text: String, _ body: (String) -> String) -> String {
    let processed = body(byteView(text.utf8))
    var bytes: [UInt8] = []
    bytes.reserveCapacity(processed.unicodeScalars.count)
    for scalar in processed.unicodeScalars {
      let value = scalar.value
      if value < 0x80 {
        bytes.append(UInt8(value))
      } else if value >= byteBase + 0x80 && value <= byteBase + 0xFF {
        bytes.append(UInt8(value - byteBase))
      } else {
        bytes.append(contentsOf: Array(String(scalar).utf8))
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// The byte-faithful view used by `byteMode`, without converting back.
  static func byteView<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var view = String.UnicodeScalarView()
    for byte in bytes {
      let value = byte < 0x80 ? UInt32(byte) : byteBase + UInt32(byte)
      view.append(Unicode.Scalar(value)!)
    }
    return String(view)
  }

  // MARK: perl -p / bash $(...)

  /// Applies `transform` to each "\n"-terminated line (the last one may have
  /// no terminator), like `perl -p`. Lines keep their "\n".
  static func eachLine(_ text: String, _ transform: (String) -> String) -> String {
    let scalars = text.unicodeScalars
    var out = ""
    var start = scalars.startIndex
    var index = start
    while index < scalars.endIndex {
      let next = scalars.index(after: index)
      if scalars[index] == "\n" {
        out += transform(String(scalars[start..<next]))
        start = next
      }
      index = next
    }
    if start < scalars.endIndex {
      out += transform(String(scalars[start..<scalars.endIndex]))
    }
    return out
  }

  /// What bash keeps from `$(...)` output: NUL bytes dropped, every trailing
  /// "\n" removed.
  static func bashCapture(_ text: String) -> String {
    var scalars = Array(text.unicodeScalars.filter { $0 != "\0" })
    while scalars.last == "\n" { scalars.removeLast() }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }

  // MARK: Small bash/Perl semantics

  /// `tr '[:upper:]' '[:lower:]'` in the C locale: ASCII letters only.
  static func asciiLowercased(_ text: String) -> String {
    var view = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if scalar.value >= 65 && scalar.value <= 90 {
        view.append(Unicode.Scalar(scalar.value + 32)!)
      } else {
        view.append(scalar)
      }
    }
    return String(view)
  }

  /// `sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'` in the C locale.
  static func asciiTrimmed(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var lower = 0
    var upper = scalars.count
    while lower < upper && asciiSpaces.contains(scalars[lower]) { lower += 1 }
    while upper > lower && asciiSpaces.contains(scalars[upper - 1]) { upper -= 1 }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[lower..<upper])
    return String(view)
  }

  /// bash `[[ -z "${text//[[:space:]]/}" ]]` in the C locale.
  static func isBlank(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { asciiSpaces.contains($0) }
  }

  /// The CLI's `bool_is_on`: 1/true/yes/on, any ASCII case.
  static func boolIsOn(_ raw: String) -> Bool {
    ["1", "true", "yes", "on"].contains(asciiLowercased(raw))
  }

  private static let numericPrefix = ICURegex(
    "^[ \\t\\n\\r\\f\\x{0B}]*([+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)")
  private static let infNanPrefix = ICURegex(
    "^[ \\t\\n\\r\\f\\x{0B}]*([+-]?)(inf(?:inity)?|nan)", caseInsensitive: true)

  /// Perl's numeric value of a string (leading whitespace, sign, decimal,
  /// exponent, trailing garbage ignored; "" and junk are 0), before `int()`.
  static func perlNumber(_ raw: String) -> Double {
    let ns = raw as NSString
    if let match = numericPrefix.matches(raw).first {
      return Double(match.group(1, in: ns)) ?? 0
    }
    if let match = infNanPrefix.matches(raw).first {
      if asciiLowercased(match.group(2, in: ns)) == "nan" { return .nan }
      return match.group(1, in: ns) == "-" ? -.infinity : .infinity
    }
    return 0
  }

  /// Perl's `int($value)` for comparisons: truncates toward zero.
  static func perlInt(_ raw: String) -> Double {
    let value = perlNumber(raw)
    return value.isFinite ? value.rounded(.towardZero) : value
  }

  /// Compares strings the way Perl's `cmp` does on character strings: by
  /// code point. Swift's `<` on String uses Unicode canonical ordering.
  static func codePointLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
  }

  /// Perl's `length` on a character string: code points, not graphemes.
  static func perlLength(_ text: String) -> Int {
    text.unicodeScalars.count
  }

  /// Splits into "\n"-separated lines without terminators, like reading a
  /// file with `read -r` / `<$fh>` + chomp. A trailing "\n" adds no line.
  static func fileLines(_ text: String) -> [String] {
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var pending = false
    for scalar in text.unicodeScalars {
      if scalar == "\n" {
        lines.append(String(current))
        current = String.UnicodeScalarView()
        pending = false
      } else {
        current.append(scalar)
        pending = true
      }
    }
    if pending { lines.append(String(current)) }
    return lines
  }

  /// File contents as text, bytes decoded leniently (no BOM stripping).
  static func readFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// `[[ -f path ]]`: a regular file, following symlinks.
  static func isFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  /// `[[ -d path ]]`: a directory, following symlinks.
  static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}
