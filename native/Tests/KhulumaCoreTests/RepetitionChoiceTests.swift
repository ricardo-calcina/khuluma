import Foundation
import Testing
@testable import KhulumaCore

/// The two Settings controls ↔ one stored level, and the combined levels
/// 4/5 of cleanRepeats (0–3 are the bash CLI's and unchanged).
struct RepetitionChoiceTests {
  @Test func levelsRoundTrip() {
    for (level, sentences, words) in [
      ("0", false, RepetitionChoice.Words.keep), ("1", false, .words), ("2", false, .phrases),
      ("3", true, .keep), ("4", true, .words), ("5", true, .phrases),
    ] {
      let choice = RepetitionChoice(level: level)
      #expect(choice.sentences == sentences && choice.words == words)
      #expect(choice.level == level)
    }
  }

  @Test func unknownLevelsReadAsKeep() {
    for level in ["", "6", "abc", "-1", "10"] {
      let choice = RepetitionChoice(level: level)
      #expect(choice.sentences == false && choice.words == .keep && choice.level == "0")
    }
  }

  @Test func eachControlKeepsTheOther() {
    var choice = RepetitionChoice(level: "5")
    choice.sentences = false
    #expect(choice.level == "2")
    choice = RepetitionChoice(level: "5")
    choice.words = .keep
    #expect(choice.level == "3")
  }
}

struct RepeatsLevel45Tests {
  private let doubles = "I I think that that works"
  private let restart = "make that a branded a branded entry"
  /// Six words ending in a period: the sentence rule needs the stop.
  private let sentence = "The plan is ready for launch."

  /// 0–3 outputs for the level-4/5 inputs, pinning that they did not move.
  @Test func levelsZeroToThreeAreUnchanged() {
    #expect(TextCleanup.cleanRepeats(doubles, level: 0) == doubles)
    #expect(TextCleanup.cleanRepeats(doubles, level: 1) == "I think that works")
    #expect(TextCleanup.cleanRepeats(doubles, level: 2) == "I think that works")
    #expect(TextCleanup.cleanRepeats(doubles, level: 3) == doubles)
    #expect(TextCleanup.cleanRepeats(restart, level: 2) == "make that a branded entry")
    #expect(TextCleanup.cleanRepeats(restart, level: 3) == restart)
    #expect(TextCleanup.cleanRepeats(sentence + " " + sentence, level: 2)
            == sentence + " " + sentence)
  }

  @Test func level4IsSentencesPlusSingleWords() {
    #expect(TextCleanup.cleanRepeats(doubles, level: 4) == "I think that works")
    // Two-word phrase restarts stay at 4.
    #expect(TextCleanup.cleanRepeats(restart, level: 4) == restart)
    #expect(TextCleanup.cleanRepeats(sentence + " " + sentence, level: 4) == sentence)
  }

  @Test func level5IsSentencesPlusWordsPlusPhrases() {
    #expect(TextCleanup.cleanRepeats(doubles, level: 5) == "I think that works")
    #expect(TextCleanup.cleanRepeats(restart, level: 5) == "make that a branded entry")
    #expect(TextCleanup.cleanRepeats(sentence + " " + sentence, level: 5) == sentence)
  }

  @Test func pipelineLevel5CleansTheRestartAfterTheFiller() {
    let settings = CleanupSettings(configDir: "/tmp/x", clean: "1", repeatsLevel: "5",
                                   britishSpelling: "0", localeCtype: "C", localeCollate: "")
    let sheet = VocabularySheet(fillers: ["uh"], brands: [], words: [])
    let outcome = TextPipeline(settings: settings).preview(
      transcript: "So make that a branded uh a branded entry.", sheet: sheet)
    #expect(outcome == .text(raw: "So make that a branded entry.",
                             text: "So make that a branded entry."))
  }
}
