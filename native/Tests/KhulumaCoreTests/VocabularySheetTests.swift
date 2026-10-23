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
}
