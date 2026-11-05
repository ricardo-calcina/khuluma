import Foundation

/// Portable document shared with the CLI. Rules are literal text, never regex.
public struct VocabularySheet: Codable, Equatable, Sendable {
  public struct Correction: Codable, Equatable, Sendable {
    public var heard: String
    public var write: String
    public init(heard: String, write: String) { self.heard = heard; self.write = write }
  }
  /// A saved check: what was heard, and the text cleanup should deliver.
  /// Cleanup ignores examples; the editor reruns them before each save.
  public struct Example: Codable, Equatable, Hashable, Sendable {
    public var said: String
    public var expect: String
    public init(said: String, expect: String) { self.said = said; self.expect = expect }
  }
  public var schemaVersion: Int = 1
  public var fillers: [String]
  public var brands: [Correction]
  public var words: [Correction]
  /// Optional; omitted from the file when there are none.
  public var examples: [Example]?
  public static let maximumExamples = 200
  public static let maximumBytes = 1_048_576
  public static let empty = VocabularySheet(fillers: [], brands: [], words: [])
  public static let defaults = VocabularySheet(
    fillers: ["um", "umm", "ummm", "uh", "uhh", "uhhh", "erm"], brands: [], words: [])

  enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", fillers, brands, words, examples }
  public init(fillers: [String], brands: [Correction], words: [Correction]) {
    self.fillers = fillers; self.brands = brands; self.words = words
  }

  public enum Invalid: LocalizedError {
    case document(String)
    public var errorDescription: String? {
      switch self { case .document(let message): return message }
    }
  }

  /// The CLI's `vocab-sheet validate`: same rules and messages as
  /// `bin/khuluma-lib/vocabulary.py`. Unknown fields, duplicate JSON fields
  /// and wrong shapes are errors rather than silently lost.
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw Invalid.document("Choose a vocabulary JSON file smaller than 1 MB.") }
    let tree: Any
    do { tree = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
      throw Invalid.document("The vocabulary is not valid JSON.")
    }
    if let key = JSONDuplicateFields.first(in: data) { throw Invalid.document("Duplicate JSON field: \(key)") }
    return try validate(tree: tree)
  }

  public func validated() throws -> Self {
    var tree: [String: Any] = [
      "schema_version": schemaVersion, "fillers": fillers,
      "brands": brands.map { ["heard": $0.heard, "write": $0.write] },
      "words": words.map { ["heard": $0.heard, "write": $0.write] },
    ]
    if let examples { tree["examples"] = examples.map { ["said": $0.said, "expect": $0.expect] } }
    return try Self.validate(tree: tree)
  }

  /// `validate()` of vocabulary.py, on a parsed JSON tree.
  static func validate(tree value: Any) throws -> Self {
    func fail(_ message: String) -> Invalid { .document(message) }
    func isInteger(_ value: Any?) -> Bool {
      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
      return !CFNumberIsFloatType(number)
    }
    func plain(_ text: String) -> Bool { !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    guard let object = value as? [String: Any],
          Set(object.keys).subtracting(["examples"]) == ["schema_version", "fillers", "brands", "words"] else {
      throw fail("Use schema_version, fillers, brands and words in the vocabulary JSON.")
    }
    guard isInteger(object["schema_version"]), (object["schema_version"] as? NSNumber)?.intValue == 1 else {
      throw fail("This vocabulary version is not supported. Use schema_version 1.")
    }
    var seen = Set<String>()
    var total = 0
    func term(_ value: Any?) throws -> String {
      guard let text = value as? String, !(value is NSNull) else {
        throw fail("Each word or phrase must be 1–200 characters on one line.")
      }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, text.unicodeScalars.count <= 200, plain(text) else {
        throw fail("Each word or phrase must be 1–200 characters on one line.")
      }
      return trimmed
    }
    var result = VocabularySheet(fillers: [], brands: [], words: [])
    for section in ["fillers", "brands", "words"] {
      guard let entries = object[section] as? [Any] else { throw fail("\(section) must be a list.") }
      for entry in entries {
        total += 1
        guard total <= 5000 else { throw fail("A vocabulary can contain up to 5,000 entries.") }
        let heard: String
        var correction: Correction?
        if section == "fillers" {
          heard = try term(entry)
        } else {
          guard let pair = entry as? [String: Any], Set(pair.keys) == ["heard", "write"] else {
            throw fail("Each \(section) entry needs heard and write text.")
          }
          heard = try term(pair["heard"])
          correction = Correction(heard: heard, write: try term(pair["write"]))
        }
        guard seen.insert(heard.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
          throw fail("“\(heard)” appears more than once. Keep each heard phrase in one section.")
        }
        switch section {
        case "fillers": result.fillers.append(heard)
        case "brands": result.brands.append(correction!)
        default: result.words.append(correction!)
        }
      }
    }
    let rawExamples = object["examples"] ?? [Any]()
    guard let examples = rawExamples as? [Any], examples.count <= maximumExamples else {
      throw fail("examples must be a list of up to 200 entries.")
    }
    var kept: [Example] = []
    for example in examples {
      guard let pair = example as? [String: Any], Set(pair.keys) == ["said", "expect"] else {
        throw fail("Each example needs said and expect text.")
      }
      for text in pair.values {
        guard let text = text as? String, text.unicodeScalars.count <= 2000, plain(text) else {
          throw fail("Each example must be at most 2,000 characters on one line.")
        }
      }
      let said = pair["said"] as! String, expect = pair["expect"] as! String
      guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw fail("Each example needs the text that was heard.")
      }
      kept.append(Example(said: said, expect: expect))
    }
    result.examples = kept.isEmpty ? nil : kept
    return result
  }

  public var count: Int { fillers.count + brands.count + words.count }
  /// The file's bytes: the same layout as the CLI wrote (`json.dumps(indent=2)`
  /// plus a newline), so a person or agent diffing it sees no churn.
  public func encoded() throws -> Data {
    let sheet = try validated()
    func str(_ text: String) -> String {
      var out = "\""
      for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
          out += scalar.value < 32 ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }
      }
      return out + "\""
    }
    func block(_ name: String, _ items: [[(String, String)]?], plain: [String]?) -> String {
      var out = "  \"\(name)\": "
      let rendered: [String]
      if let plain { rendered = plain.map { "    " + str($0) } } else {
        rendered = items.map { item in
          "    {\n" + item!.map { "      \(str($0.0)): \(str($0.1))" }.joined(separator: ",\n") + "\n    }"
        }
      }
      out += rendered.isEmpty ? "[]" : "[\n" + rendered.joined(separator: ",\n") + "\n  ]"
      return out
    }
    var parts = [
      "  \"schema_version\": 1",
      block("fillers", [], plain: sheet.fillers),
      block("brands", sheet.brands.map { [("heard", $0.heard), ("write", $0.write)] }, plain: nil),
      block("words", sheet.words.map { [("heard", $0.heard), ("write", $0.write)] }, plain: nil),
    ]
    if let examples = sheet.examples {
      parts.append(block("examples", examples.map { [("said", $0.said), ("expect", $0.expect)] }, plain: nil))
    }
    let data = Data(("{\n" + parts.joined(separator: ",\n") + "\n}\n").utf8)
    guard data.count <= Self.maximumBytes else { throw Invalid.document("Choose a vocabulary JSON file smaller than 1 MB.") }
    return data
  }
  public static func path(configDir: String) -> String { configDir + "/vocabulary.json" }
  public static func load(configDir: String) throws -> Self? {
    let path = path(configDir: configDir)
    let url = URL(fileURLWithPath: path)
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw Invalid.document("vocabulary.json must be a regular file, not a symbolic link.")
    }
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
      throw Invalid.document("Choose a vocabulary JSON file smaller than 1 MB.")
    }
    return try decode(Data(contentsOf: url))
  }
}

public struct VocabularySnapshot: Codable, Equatable, Sendable {
  public var document: VocabularySheet
  public var revision: String
  public init(document: VocabularySheet, revision: String) { self.document = document; self.revision = revision }
}

/// The first repeated field name in a JSON document (which
/// `JSONSerialization` would silently collapse), in parse order. The caller
/// has already parsed `data`, so the syntax is known to be valid.
enum JSONDuplicateFields {
  static func first(in data: Data) -> String? {
    let bytes = [UInt8](data)
    var stack: [(isObject: Bool, expectKey: Bool, keys: Set<String>)] = []
    var index = 0
    while index < bytes.count {
      switch bytes[index] {
      case UInt8(ascii: "{"): stack.append((true, true, []))
      case UInt8(ascii: "["): stack.append((false, false, []))
      case UInt8(ascii: "}"), UInt8(ascii: "]"): _ = stack.popLast()
      case UInt8(ascii: ","): if let top = stack.last, top.isObject { stack[stack.count - 1].expectKey = true }
      case UInt8(ascii: "\""):
        let start = index
        index += 1
        while index < bytes.count, bytes[index] != UInt8(ascii: "\"") { index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1 }
        if let top = stack.last, top.isObject, top.expectKey {
          stack[stack.count - 1].expectKey = false
          let literal = Data(bytes[start..<min(index + 1, bytes.count)])
          if let key = (try? JSONSerialization.jsonObject(with: literal, options: [.fragmentsAllowed])) as? String,
             !stack[stack.count - 1].keys.insert(key).inserted { return key }
        }
      default: break
      }
      index += 1
    }
    return nil
  }
}
