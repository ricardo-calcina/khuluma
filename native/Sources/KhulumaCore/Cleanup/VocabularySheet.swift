import Foundation

/// Portable document shared with the CLI. Rules are literal text, never regex.
public struct VocabularySheet: Codable, Equatable, Sendable {
  public struct Correction: Codable, Equatable, Sendable {
    public var heard: String
    public var write: String
    public init(heard: String, write: String) { self.heard = heard; self.write = write }
  }
  public var schemaVersion: Int = 1
  public var fillers: [String]
  public var brands: [Correction]
  public var words: [Correction]
  public static let maximumBytes = 1_048_576
  public static let empty = VocabularySheet(fillers: [], brands: [], words: [])
  public static let defaults = VocabularySheet(
    fillers: ["um", "umm", "ummm", "uh", "uhh", "uhhh", "erm"], brands: [], words: [])

  enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", fillers, brands, words }
  public init(fillers: [String], brands: [Correction], words: [Correction]) {
    self.fillers = fillers; self.brands = brands; self.words = words
  }

  public enum Invalid: LocalizedError {
    case document(String)
    public var errorDescription: String? {
      switch self { case .document(let message): return message }
    }
  }

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes else { throw Invalid.document("Choose a vocabulary JSON file smaller than 1 MB.") }
    // Reject unknown fields rather than silently losing an agent's additions.
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == ["schema_version", "fillers", "brands", "words"] else {
      throw Invalid.document("Use schema_version, fillers, brands and words in the vocabulary JSON.")
    }
    for key in ["brands", "words"] {
      guard let entries = object[key] as? [[String: Any]],
            entries.allSatisfy({ Set($0.keys) == ["heard", "write"] }) else {
        throw Invalid.document("Each \(key) entry needs heard and write text.")
      }
    }
    return try JSONDecoder().decode(Self.self, from: data).validated()
  }

  public func validated() throws -> Self {
    guard schemaVersion == 1 else { throw Invalid.document("This vocabulary version is not supported. Use schema_version 1.") }
    guard count <= 5000 else { throw Invalid.document("A vocabulary can contain up to 5,000 entries.") }
    var seen = Set<String>()
    func term(_ value: String, heard: Bool) throws -> String {
      let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, value.unicodeScalars.count <= 200,
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
        throw Invalid.document("Each word or phrase must be 1–200 characters on one line.")
      }
      if heard, !seen.insert(text.lowercased()).inserted {
        throw Invalid.document("“\(text)” appears more than once. Keep each heard phrase in one section.")
      }
      return text
    }
    var result = self
    result.fillers = try fillers.map { try term($0, heard: true) }
    func corrections(_ entries: [Correction]) throws -> [Correction] {
      try entries.map { Correction(heard: try term($0.heard, heard: true), write: try term($0.write, heard: false)) }
    }
    result.brands = try corrections(brands)
    result.words = try corrections(words)
    return result
  }

  public var count: Int { fillers.count + brands.count + words.count }
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(validated())
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
