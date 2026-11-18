import Foundation
import Testing
@testable import KhulumaCore

@Suite struct SpokenFormattingTests {
  static let cases: [(String, String)] = [
    ("First point. New line. Second point", "First point.\nSecond point"),
    ("first point, new paragraph, second point", "first point\n\nSecond point"),
    ("First point. New paragraph. Second point.", "First point.\n\nSecond point."),
    ("One, newline, two", "One\nTwo"),
    ("One. NEW LINE. two", "One.\nTwo"),
    ("One? New Line! Two", "One?\nTwo"),
    ("New line. Hello there", "Hello there"),
    ("Hello there. New line.", "Hello there."),
    ("Hello there, new line", "Hello there"),
    ("point one, new line point two", "point one\nPoint two"),
    ("One. New line. New line. New line. Two", "One.\n\nTwo"),
    ("One. New paragraph. New paragraph. Two", "One.\n\nTwo"),
    ("One. New line. Two. New line. Three", "One.\nTwo.\nThree"),
    ("Dear Sam, new line, thanks for this.", "Dear Sam\nThanks for this."),
    // Ordinary speech stays.
    ("We launched a new line of products today.", "We launched a new line of products today."),
    ("I think the new paragraph was better.", "I think the new paragraph was better."),
    ("Add a newline character here", "Add a newline character here"),
    ("I drew a new line.", "I drew a new line."),
    ("Start a new paragraph.", "Start a new paragraph."),
    ("point one new line point two", "point one new line point two"),
    // No commands: unchanged.
    ("Plain text,  with  spaces  ", "Plain text,  with  spaces  "),
    ("", ""),
    // Only a command: left as said.
    ("New line.", "New line."),
  ]

  @Test(arguments: cases)
  func formats(_ input: String, _ expected: String) {
    #expect(SpokenFormatting.apply(input) == expected)
  }

  @Test func outcomeOnlyWhenOn() {
    var settings = CleanupSettings(configDir: "/tmp")
    let outcome = CleanupOutcome.text(raw: "a. New line. b", text: "a. New line. b")
    #expect(outcome.formatted(settings) == outcome)
    settings.spokenFormatting = "1"
    #expect(outcome.formatted(settings) == .text(raw: "a. New line. b", text: "a.\nB"))
    #expect(CleanupOutcome.noSpeech.formatted(settings) == .noSpeech)
  }
}

@Suite struct SpokenFormattingSettingTests {
  @Test func missingDecodesAsOff() throws {
    let cleanup = try JSONDecoder().decode(AppSettings.Cleanup.self, from: Data("{}".utf8))
    #expect(cleanup.spokenFormatting == false)
  }
}
