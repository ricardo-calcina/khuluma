import Foundation

/// A small TOML reader for what the CLI's `config.toml` uses: `[table]` and
/// dotted `[a.b]` headers, `key = value` with bare or quoted keys, basic and
/// literal strings (with escapes), booleans, integers, floats, arrays of
/// strings, and comments. Anything else on a line (inline tables, dates,
/// multi-line strings or arrays, dotted keys) is reported as unreadable for
/// that key rather than guessed; a malformed header or line makes the whole
/// file invalid, as `tomllib` would.
public enum TOMLReader {
  public enum Value: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case float(Double)
    case strings([String])
  }

  public struct Document: Equatable, Sendable {
    /// Readable keys by dotted path (`audio.sounds.start`).
    public var values: [String: Value] = [:]
    /// Keys whose value this reader can't read, with why.
    public var unreadable: [(path: String, reason: String)] = []

    public static func == (a: Document, b: Document) -> Bool {
      a.values == b.values && a.unreadable.map(\.path) == b.unreadable.map(\.path)
    }
  }

  public struct ParseError: Error, LocalizedError, Equatable, Sendable {
    public let line: Int
    public let message: String
    public var errorDescription: String? { "line \(line): \(message)" }
  }

  public static func parse(_ text: String) throws -> Document {
    var doc = Document()
    var table: [String] = []
    var seenTables = Set<String>()
    var lineNo = 0
    for raw in text.components(separatedBy: "\n") {
      lineNo += 1
      let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
      var s = Scanner(Array(line.unicodeScalars), line: lineNo)
      s.skipSpace()
      if s.atEnd || s.peek == "#" { continue }
      if s.peek == "[" {
        s.advance()
        if s.peek == "[" { throw ParseError(line: lineNo, message: "arrays of tables are not supported") }
        let path = try s.keyPath(until: "]")
        guard s.peek == "]" else { throw ParseError(line: lineNo, message: "expected ]") }
        s.advance()
        try s.endOfLine()
        let joined = canonical(path)
        guard seenTables.insert(joined).inserted else { throw ParseError(line: lineNo, message: "table [\(joined)] defined twice") }
        table = path
        continue
      }
      let keyPath = try s.keyPath(until: "=")
      guard s.peek == "=" else { throw ParseError(line: lineNo, message: "expected =") }
      s.advance()
      s.skipSpace()
      let full = canonical(table + keyPath)
      if doc.values[full] != nil || doc.unreadable.contains(where: { $0.path == full }) {
        throw ParseError(line: lineNo, message: "key \(full) defined twice")
      }
      if keyPath.count > 1 {
        doc.unreadable.append((full, "dotted keys are not read"))
        continue
      }
      do {
        let value = try s.value()
        try s.endOfLine()
        doc.values[full] = value
      } catch let unsupported as Unsupported {
        doc.unreadable.append((full, unsupported.reason))
        // A multi-line value would continue on later lines; refuse rather
        // than misread them as keys.
        if unsupported.multiline { throw ParseError(line: lineNo, message: "multi-line values are not supported (\(full))") }
      }
    }
    return doc
  }

  /// The dotted path of key components. A component that isn't a valid
  /// bare key (`"inline.autosend"`, quoted because of the dot) stays quoted,
  /// so it never matches the real nested key, as in tomllib.
  public static func canonical(_ components: [String]) -> String {
    components.map { part in
      !part.isEmpty && part.unicodeScalars.allSatisfy(Scanner.isBare) ? part
        : "\"" + part.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }.joined(separator: ".")
  }

  struct Unsupported: Error {
    let reason: String
    var multiline = false
  }

  struct Scanner {
    let c: [Unicode.Scalar]
    var i = 0
    let line: Int
    init(_ c: [Unicode.Scalar], line: Int) { self.c = c; self.line = line }

    var atEnd: Bool { i >= c.count }
    var peek: Unicode.Scalar? { atEnd ? nil : c[i] }
    mutating func advance() { i += 1 }
    func fail(_ m: String) -> ParseError { ParseError(line: line, message: m) }

    mutating func skipSpace() { while let p = peek, p == " " || p == "\t" { advance() } }

    mutating func endOfLine() throws {
      skipSpace()
      if atEnd || peek == "#" { return }
      throw fail("unexpected text after value")
    }

    static func isBare(_ p: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(p) || ("A"..."Z").contains(p) || ("0"..."9").contains(p) || p == "_" || p == "-"
    }

    mutating func keyPath(until end: Unicode.Scalar) throws -> [String] {
      var parts: [String] = []
      while true {
        skipSpace()
        guard let p = peek else { throw fail("unexpected end of line in key") }
        if p == "\"" { advance(); parts.append(try basicString()) }
        else if p == "'" { advance(); parts.append(try literalString()) }
        else {
          var k = ""
          while let q = peek, Scanner.isBare(q) { k.unicodeScalars.append(q); advance() }
          guard !k.isEmpty else { throw fail("invalid key") }
          parts.append(k)
        }
        skipSpace()
        if peek == "." { advance(); continue }
        guard peek == end else { throw fail("expected \(end)") }
        return parts
      }
    }

    mutating func basicString() throws -> String {
      var out = ""
      while let p = peek {
        advance()
        if p == "\"" { return out }
        if p == "\\" {
          guard let e = peek else { throw fail("unterminated escape") }
          advance()
          switch e {
          case "b": out += "\u{08}"
          case "t": out += "\t"
          case "n": out += "\n"
          case "f": out += "\u{0C}"
          case "r": out += "\r"
          case "e": out += "\u{1B}"
          case "\"": out += "\""
          case "\\": out += "\\"
          case "u", "U":
            let n = e == "u" ? 4 : 8
            guard i + n <= c.count else { throw fail("short unicode escape") }
            let hex = String(String.UnicodeScalarView(c[i..<i + n]))
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { throw fail("invalid unicode escape") }
            out.unicodeScalars.append(scalar)
            i += n
          default: throw fail("invalid escape \\\(e)")
          }
          continue
        }
        if p.value < 0x20 && p != "\t" || p.value == 0x7F { throw fail("control character in string") }
        out.unicodeScalars.append(p)
      }
      throw fail("unterminated string")
    }

    mutating func literalString() throws -> String {
      var out = ""
      while let p = peek {
        advance()
        if p == "'" { return out }
        if p.value < 0x20 && p != "\t" || p.value == 0x7F { throw fail("control character in string") }
        out.unicodeScalars.append(p)
      }
      throw fail("unterminated string")
    }

    mutating func string() throws -> String {
      let q = peek!
      // Multi-line strings start with three quotes.
      if i + 2 < c.count, c[i + 1] == q, c[i + 2] == q { throw Unsupported(reason: "multi-line strings are not read", multiline: true) }
      advance()
      return q == "\"" ? try basicString() : try literalString()
    }

    mutating func value() throws -> Value {
      guard let p = peek else { throw fail("missing value") }
      if p == "\"" || p == "'" { return .string(try string()) }
      if p == "{" { throw Unsupported(reason: "inline tables are not read") }
      if p == "[" { return try array() }
      var word = ""
      while let q = peek, q != " ", q != "\t", q != "#", q != ",", q != "]" { word.unicodeScalars.append(q); advance() }
      if word == "true" { return .bool(true) }
      if word == "false" { return .bool(false) }
      if let n = Scanner.integer(word) { return .int(n) }
      if let d = Scanner.float(word) { return .float(d) }
      if word.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil || word.range(of: #"^\d{2}:\d{2}"#, options: .regularExpression) != nil {
        // Rest of a date-time may follow a space; stop reading this line.
        i = c.count
        throw Unsupported(reason: "dates and times are not read")
      }
      throw fail("invalid value \(word)")
    }

    static func integer(_ w: String) -> Int? {
      let digits = w.hasPrefix("+") || w.hasPrefix("-") ? String(w.dropFirst()) : w
      if digits.hasPrefix("0x") || digits.hasPrefix("0o") || digits.hasPrefix("0b") {
        guard w == digits else { return nil }
        let radix = digits.hasPrefix("0x") ? 16 : digits.hasPrefix("0o") ? 8 : 2
        return validUnderscores(String(digits.dropFirst(2))).flatMap { Int($0, radix: radix) }
      }
      guard let clean = validUnderscores(digits), clean.allSatisfy(\.isASCIIDigit) else { return nil }
      if clean.count > 1 && clean.hasPrefix("0") { return nil }
      return Int((w.hasPrefix("-") ? "-" : "") + clean)
    }

    static func validUnderscores(_ s: String) -> String? {
      guard !s.isEmpty, !s.hasPrefix("_"), !s.hasSuffix("_"), !s.contains("__") else { return nil }
      return s.replacingOccurrences(of: "_", with: "")
    }

    static func float(_ w: String) -> Double? {
      let unsigned = w.hasPrefix("+") || w.hasPrefix("-") ? String(w.dropFirst()) : w
      if unsigned == "inf" { return w.hasPrefix("-") ? -.infinity : .infinity }
      if unsigned == "nan" { return .nan }
      guard w.range(of: #"^[+-]?(0|[1-9](_?\d)*)(\.\d(_?\d)*)?([eE][+-]?\d(_?\d)*)?$"#, options: .regularExpression) != nil,
            unsigned.contains(".") || unsigned.lowercased().contains("e") else { return nil }
      return Double(w.replacingOccurrences(of: "_", with: ""))
    }

    mutating func array() throws -> Value {
      advance()
      var items: [String] = []
      while true {
        skipSpace()
        guard let p = peek else { throw Unsupported(reason: "multi-line arrays are not read", multiline: true) }
        if p == "#" { throw Unsupported(reason: "multi-line arrays are not read", multiline: true) }
        if p == "]" { advance(); return .strings(items) }
        guard p == "\"" || p == "'" else {
          // Skip to the closing bracket so the line's end can be checked.
          var depth = 0
          while let q = peek { advance(); if q == "[" { depth += 1 } else if q == "]" { if depth == 0 { break }; depth -= 1 } }
          throw Unsupported(reason: "arrays of non-strings are not read")
        }
        items.append(try string())
        skipSpace()
        if peek == "," { advance(); continue }
        skipSpace()
        guard peek == "]" else {
          if atEnd || peek == "#" { throw Unsupported(reason: "multi-line arrays are not read", multiline: true) }
          throw fail("expected , or ] in array")
        }
      }
    }
  }
}

private extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}
