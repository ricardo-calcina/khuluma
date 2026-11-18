import Testing
@testable import KhulumaCore

/// LiveTranscript.FinalPass: the stop-time pass reaches back into covered
/// audio and only ever extends the prefix at shared words.
struct LiveFinalPassTests {
  private let rate = 16_000
  private func start(covered: Double, total: Double) -> Int {
    LiveTranscript.FinalPass.windowStart(coveredSamples: Int(covered * Double(rate)),
                                         totalSamples: Int(total * Double(rate)), sampleRate: rate)
  }

  @Test func aShortTailIsWidenedToFifteenSeconds() {
    // 128.7 s take, last cut at 120.8 s: the window starts at 113.7 s.
    #expect(LiveTranscript.FinalPass.windowStart(coveredSamples: 1_932_800, totalSamples: 2_059_200,
                                                 sampleRate: rate) == 1_819_200)
  }

  @Test func aLongTailStillGetsFourSecondsOfContext() {
    #expect(start(covered: 30, total: 55) == 26 * rate)
  }

  @Test func theWindowNeverStartsBeforeTheTake() {
    #expect(start(covered: 12, total: 13) == 0)
  }

  @Test func newTailWordsExtendThePrefixOnce() {
    #expect(LiveTranscript.FinalPass.merge(
      prefix: "the rescan after fixing everything else",
      window: "after fixing everything else would show a more true amount.")
      == "the rescan after fixing everything else would show a more true amount.")
  }

  @Test func aWindowThatAddsNothingKeepsThePrefix() {
    // Trailing silence: the window only repeats covered words.
    let prefix = "make one that is bespoke to that business and industry."
    #expect(LiveTranscript.FinalPass.merge(prefix: prefix, window: "bespoke to that business and industry")
      == prefix)
  }

  @Test func noSharedWordsAsksForTheTailAlone() {
    #expect(LiveTranscript.FinalPass.merge(prefix: "the big cat sat", window: "a dog ran off") == nil)
    #expect(LiveTranscript.FinalPass.merge(prefix: "the big cat sat", window: "") == nil)
  }

  @Test func aPhraseRepeatedInTheTailIsKept() {
    #expect(LiveTranscript.FinalPass.merge(
      prefix: "please send the report",
      window: "please send the report and then please send the report to finance")
      == "please send the report and then please send the report to finance")
  }

  @Test func overlapHeardDifferentlyFallsBackInsteadOfDroppingWords() {
    #expect(LiveTranscript.FinalPass.merge(
      prefix: "the budget is one hundred and twenty five dollars",
      window: "the budget is 125 dollars total") == nil)
  }

  @Test func theWindowMayReHearThePrefixsLastWord() {
    #expect(LiveTranscript.FinalPass.merge(
      prefix: "I will find a way to make this more seemless",
      window: "find a way to make this more seamless for everyone")
      == "I will find a way to make this more seamless for everyone")
  }

  @Test func aWindowMissingThePrefixsLastWordsFallsBack() {
    #expect(LiveTranscript.FinalPass.merge(
      prefix: "show a more true amount of data",
      window: "show a more true amount") == nil)
  }

  @Test func theContextRunBeatsAShorterRepeatLater() {
    #expect(LiveTranscript.FinalPass.merge(
      prefix: "we looked at it and it was fine",
      window: "looked at it and it was fine so it was fine")
      == "we looked at it and it was fine so it was fine")
  }

  @Test func aLongRepeatedPrefixIsNotDuplicated() {
    let prefix = Array(repeating: "please send the report", count: 7).joined(separator: " ")
    #expect(LiveTranscript.FinalPass.merge(prefix: prefix, window: prefix + " to finance")
      == prefix + " to finance")
  }
}
