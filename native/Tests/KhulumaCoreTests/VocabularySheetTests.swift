import Foundation
import Testing
@testable import KhulumaCore

struct VocabularySheetTests {
  @Test func roundTripIncludesEverySection() throws {
    let sheet = VocabularySheet(fillers: ["um", "ahhh"],
      brands: [.init(heard: "Kaluma", write: "Khuluma")], words: [.init(heard: "source slash", write: "src/")])
    #expect(try VocabularySheet.decode(sheet.encoded()) == sheet)
  }
  @Test func rejectsDuplicateHeardPhrasesAcrossSections() {
    let sheet = VocabularySheet(fillers: ["um"], brands: [.init(heard: "UM", write: "University")], words: [])
    #expect(throws: (any Error).self) { try sheet.validated() }
  }
  @Test func rejectsUnknownVersionAndFields() {
    for json in [#"{"schema_version":2,"fillers":[],"brands":[],"words":[]}"#,
                 #"{"schema_version":1,"fillers":[],"brands":[],"words":[],"extra":[]}"#,
                 #"{"schema_version":1,"fillers":[],"brands":[{"heard":"a","write":"b","x":1}],"words":[]}"#] {
      #expect(throws: (any Error).self) { try VocabularySheet.decode(Data(json.utf8)) }
    }
  }
  @Test func customFillersAreLiteralAndCanBeEmpty() {
    #expect(TextCleanup.cleanFillers("Ahhh, er x+ keep um.", words: ["ahhh", "er", "x+"]) == "keep um.")
    #expect(TextCleanup.cleanFillers("Um, uh, keep this.", words: []) == "Um, uh, keep this.")
    #expect(TextCleanup.cleanFillers(#"The word "ahhh" and /ahhh/file stay."#, words: ["ahhh"]) ==
      #"The word "ahhh" and /ahhh/file stay."#)
  }

  @Test func examplesAreOptionalAndOmittedWhenEmpty() throws {
    var sheet = VocabularySheet(fillers: [], brands: [], words: [])
    sheet.examples = []
    #expect(!String(decoding: try sheet.encoded(), as: UTF8.self).contains("examples"))
    sheet.examples = [.init(said: "open kaluma", expect: "open Khuluma")]
    #expect(try VocabularySheet.decode(sheet.encoded()) == sheet)
    #expect(throws: (any Error).self) {
      try VocabularySheet.decode(Data(#"{"schema_version":1,"fillers":[],"brands":[],"words":[],"examples":[{"said":"a"}]}"#.utf8))
    }
  }

  @Test func examplesCheckTheDraftNotTheSavedFile() throws {
    var sheet = VocabularySheet(fillers: ["um"], brands: [.init(heard: "PN PM", write: "pnpm")], words: [])
    sheet.examples = [.init(said: "Um, use PN PM.", expect: "use pnpm."), .init(said: "open kaluma", expect: "open Khuluma")]
    // No vocabulary.json in this directory: only the draft's rules apply.
    let pipeline = TextPipeline(settings: CleanupSettings(configDir: "/nonexistent", clean: "1", repeatsLevel: "3"))
    let failures = try #require(pipeline.failingExamples(sheet))
    #expect(failures.map(\.example.said) == ["open kaluma"])
    #expect(failures.first?.got == "open kaluma")
    let rule = try #require(TextChange.suggestedRule(got: "open kaluma.", expected: "open Khuluma."))
    #expect(rule == .init(heard: "kaluma", write: "Khuluma"))
    sheet.words.append(rule)
    #expect(try #require(pipeline.failingExamples(sheet)).isEmpty)
  }

  @Test func changesAreReportedAsWordRuns() {
    #expect(TextChange.between("use PN PM now", "use pnpm now") == [.init(before: "PN PM", after: "pnpm")])
    #expect(TextChange.between("um hello there", "hello there") == [.init(before: "um", after: "")])
    #expect(TextChange.between("same text", "same text").isEmpty)
    // Two separate fixes can't be one literal rule.
    #expect(TextChange.suggestedRule(got: "a kaluma b pn pm", expected: "a Khuluma b pnpm") == nil)
  }
}
