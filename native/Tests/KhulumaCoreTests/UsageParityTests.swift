import Foundation
import Testing

@testable import KhulumaCore

/// `UsageReportBuilder` against the repo CLI's `usage --json --days all`
/// (tests/fixtures/usage-parity/cases.json, from tests/gen_usage_parity_fixtures.py
/// with a fixed clock and time zone). The decoded reports must be equal.
struct UsageParityTests {
  nonisolated(unsafe) static let cases: [[String: Any]] = {
    let url = CleanupParity.repoRoot.appendingPathComponent("tests/fixtures/usage-parity/cases.json")
    return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
  }()

  @Test(arguments: UsageParityTests.cases.map { $0["name"] as! String })
  func matchesTheCLI(name: String) throws {
    let object = try #require(Self.cases.first { ($0["name"] as! String) == name })
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("usage.json")
    if let text = object["file_text"] as? String { try Data(text.utf8).write(to: url) }

    let now = try #require(UsageReport.parseTimestamp(object["now"] as! String))
    let today = CivilDate(now, timeZone: try #require(TimeZone(identifier: object["tz"] as! String)))
    let wpm = UsageReportBuilder.typingWPM((object["wpm"] as? String).flatMap { Int($0) })

    if object["ok"] as! Bool {
      let expected = try JSONDecoder().decode(
        UsageReport.self, from: JSONSerialization.data(withJSONObject: object["expected"]!))
      let actual = try UsageReportBuilder.report(url: url, today: today, typingWPM: wpm)
      #expect(actual == expected, "\(name): report differs")
    } else {
      #expect(throws: UsageReportBuilder.Failure.self) { try UsageReportBuilder.report(url: url, today: today, typingWPM: wpm) }
    }
  }

  @Test func coversTheWholeFixture() {
    #expect(Self.cases.count >= 60)
  }
}
