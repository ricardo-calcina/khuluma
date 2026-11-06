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
    let failures = pipeline.failingExamples(sheet)
    #expect(failures.map(\.example.said) == ["open kaluma"])
    #expect(failures.first?.got == "open kaluma")
    let rule = try #require(TextChange.suggestedRule(got: "open kaluma.", expected: "open Khuluma."))
    #expect(rule == .init(heard: "kaluma", write: "Khuluma"))
    sheet.words.append(rule)
    #expect(pipeline.failingExamples(sheet).isEmpty)
  }

  @Test func changesAreReportedAsWordRuns() {
    #expect(TextChange.between("use PN PM now", "use pnpm now") == [.init(before: "PN PM", after: "pnpm")])
    #expect(TextChange.between("um hello there", "hello there") == [.init(before: "um", after: "")])
    #expect(TextChange.between("same text", "same text").isEmpty)
    // Two separate fixes can't be one literal rule.
    #expect(TextChange.suggestedRule(got: "a kaluma b pn pm", expected: "a Khuluma b pnpm") == nil)
  }
}

struct VocabularyRowsTests {
  private let sheet: VocabularySheet = {
    var sheet = VocabularySheet(fillers: ["um", "uh"], brands: [.init(heard: "Kaluma", write: "Khuluma")],
                                words: [.init(heard: "core ml", write: "CoreML"), .init(heard: "x code", write: "Xcode")])
    sheet.examples = [.init(said: "open kaluma", expect: "open Khuluma")]
    return sheet
  }()

  @Test func rowsShowEachSection() {
    #expect(sheet.rows(.fillers).map(\.heard) == ["um", "uh"])
    #expect(sheet.rows(.fillers).allSatisfy { $0.write.isEmpty })
    #expect(sheet.rows(.brands) == [.init(heard: "Kaluma", write: "Khuluma")])
    #expect(sheet.rows(.examples) == [.init(heard: "open kaluma", write: "open Khuluma")])
  }

  @Test func editingReplacesInPlaceAndNewRowsAppend() {
    let renamed = sheet.upserting(.init(heard: "core m l", write: "Core ML"), in: .words, replacing: "core ml")
    #expect(renamed.words.map(\.heard) == ["core m l", "x code"])
    #expect(renamed.words[0].write == "Core ML")
    let added = sheet.upserting(.init(heard: "er"), in: .fillers, replacing: nil)
    #expect(added.fillers == ["um", "uh", "er"])
    #expect(added.brands == sheet.brands)
  }

  @Test func aRepeatedExampleReplacesTheOldOne() {
    let repeated = sheet.upserting(.init(heard: "open kaluma", write: "Open Khuluma."), in: .examples, replacing: nil)
    #expect(repeated.examples == [.init(said: "open kaluma", expect: "Open Khuluma.")])
  }

  @Test func removesEverySelectedRow() {
    let removed = sheet.removing(["core ml", "x code"], from: .words)
    #expect(removed.words.isEmpty)
    #expect(removed.fillers == sheet.fillers)
    #expect(sheet.removing(["open kaluma"], from: .examples).examples == [])
  }

  @Test func selectionMovesToTheNextRemainingRow() {
    let rows = ["a", "b", "c", "d"].map { VocabularySheet.Row(heard: $0) }
    #expect(VocabularySheet.selectionAfterRemoving(["b", "c"], from: rows) == "d")
    #expect(VocabularySheet.selectionAfterRemoving(["d"], from: rows) == "c")
    #expect(VocabularySheet.selectionAfterRemoving(["a", "b", "c", "d"], from: rows) == nil)
    #expect(VocabularySheet.selectionAfterRemoving(["z"], from: rows) == nil)
  }
}
