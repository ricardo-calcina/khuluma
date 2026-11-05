import Darwin
import Foundation
import Testing

@testable import KhulumaCore

/// The native vocabulary store against the repo CLI's `vocab-sheet`
/// (bin/khuluma-lib/vocabulary.py). The expected outputs in
/// tests/fixtures/vocabulary-parity/cases.json come from the real CLI, run by
/// tests/gen_vocabulary_parity_fixtures.py in a throwaway config folder.
/// Documents, errors, saved bytes and backups must match; revisions are opaque
/// and not compared. Every test uses a fresh temp folder.
struct VocabularyParityTests {
  nonisolated(unsafe) static let cases: [[String: Any]] = {
    let url = CleanupParity.repoRoot.appendingPathComponent("tests/fixtures/vocabulary-parity/cases.json")
    return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
  }()

  static func makeRoot() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-vocab-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }

  /// The big inputs the fixture only names.
  static func generatedInput(_ name: String) -> String {
    func doc(words: [String]) -> String {
      #"{"schema_version":1,"fillers":[],"brands":[],"words":["# + words.joined(separator: ",") + "]}"
    }
    func entries(_ n: Int) -> [String] { (0..<n).map { #"{"heard":"w\#($0)","write":"x"}"# } }
    switch name {
    case "validate-5000-entries": return doc(words: entries(5000))
    case "validate-5001-entries": return doc(words: entries(5001))
    case "validate-too-many-before-bad-entry": return doc(words: entries(5000) + [#"{"heard":1}"#])
    case "validate-oversize": return String(repeating: " ", count: 1_048_577)
    default: fatalError("unknown generated input \(name)")
    }
  }

  static func message(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  static func sheet(from json: Any) throws -> VocabularySheet {
    try JSONDecoder().decode(VocabularySheet.self, from: JSONSerialization.data(withJSONObject: json))
  }

  @Test(arguments: VocabularyParityTests.cases.map { $0["name"] as! String })
  func matchesTheCLI(name: String) throws {
    let object = try #require(Self.cases.first { ($0["name"] as! String) == name })
    let op = object["op"] as! String
    guard op != "save-raw" else { return }  // The typed API has no raw request to get wrong.
    let root = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for (file, text) in (object["files"] as? [String: String]) ?? [:] {
      try Data(text.utf8).write(to: root.appendingPathComponent(file))
    }
    let store = VocabularyStore(root: root)
    let expectedOK = object["ok"] as! Bool
    var actual: VocabularySheet?
    var failure: Error?
    do {
      switch op {
      case "show":
        actual = try store.show().document
      case "validate":
        var input = object["input"] as? String
        if input == nil, let marker = object["input"] as? [String: Any] { input = Self.generatedInput(marker["generated"] as! String) }
        actual = try store.validate(Data(try #require(input).utf8))
      case "save":
        var revision = object["revision"] as! String
        if revision == "current" { revision = (try? store.show().revision) ?? String(repeating: "0", count: 64) }
        let document = try Self.sheet(from: try #require(object["document"]))
        actual = try store.save(VocabularySnapshot(document: document, revision: revision)).document
      default:
        Issue.record("unknown op \(op)")
      }
    } catch {
      failure = error
    }

    if expectedOK {
      #expect(failure == nil, "\(name): unexpected error \(failure.map(Self.message) ?? "")")
      let expected = try Self.sheet(from: try #require(object["result"]))
      #expect(actual == expected, "\(name): document differs")
    } else {
      let error = try #require(failure, "\(name): expected an error")
      if (object["messageParity"] as? Bool) != false {
        #expect(Self.message(error) == (object["error"] as! String), "\(name): message differs")
      }
    }

    if op == "save" {
      let sheet = root.appendingPathComponent("vocabulary.json")
      let after = try? String(contentsOf: sheet, encoding: .utf8)
      #expect(after == object["file_after"] as? String, "\(name): saved bytes differ")
      let backups = root.appendingPathComponent("vocabulary-backups")
      let names = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).sorted()
      let texts = try names.map { try String(contentsOf: backups.appendingPathComponent($0), encoding: .utf8) }
      #expect(Set(texts) == Set(object["backups_after"] as! [String]), "\(name): backups differ")
      #expect(texts.count == (object["backups_after"] as! [String]).count)
    }
  }

  @Test func coversTheWholeFixture() {
    #expect(Self.cases.count >= 60)
    #expect(Set(Self.cases.map { $0["op"] as! String }) == ["show", "validate", "save", "save-raw"])
  }
}

/// Where the repo root is, shared by the parity suites.
enum CleanupParity {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
