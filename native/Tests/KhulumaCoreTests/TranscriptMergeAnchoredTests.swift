import Testing
@testable import KhulumaCore

/// TranscriptMerge.mergeTailAnchored: the tail may extend the full
/// transcript anchored on a shared run, but it can never repeat it.
struct TranscriptMergeAnchoredTests {
  private func merge(_ full: String, _ tail: String) -> String {
    TranscriptMerge.mergeTailAnchored(full: full, tail: tail)
  }

  @Test func anIdenticalEndingKeepsFullByteForByte() {
    let full = "so  the plan is to ship it, today."
    #expect(merge(full, "to ship it today") == full)
  }

  @Test func extraTailWordsAreAppendedOnce() {
    #expect(merge("I went to the shop", "to the shop today early")
      == "I went to the shop today early")
  }

  @Test func oneWordDifferentMidTailKeepsFull() {
    #expect(merge("I said going to the shop today", "I said going to a shop today")
      == "I said going to the shop today")
  }

  @Test func aDifferentLastWordAtEqualLengthKeepsFull() {
    #expect(merge("the big cat sat", "the big cat stood") == "the big cat sat")
  }

  @Test func noSharedRunOfThreeKeepsFull() {
    // The old merge appended the tail here; the anchored one must not.
    #expect(merge("alpha beta gamma delta", "xyz different words entirely")
      == "alpha beta gamma delta")
  }

  @Test func punctuationAndCaseStillMatch() {
    let full = "Okay, so that's it."
    #expect(merge(full, "okay so that's it") == full)
  }

  @Test func aTailThatLostWordsKeepsFull() {
    #expect(merge("we should leave now please", "we should leave")
      == "we should leave now please")
  }

  @Test func aMatchInsideTheLastEightyTokensWorks() {
    let filler = (1...100).map { "w\($0)" }.joined(separator: " ")
    let full = filler + " the red car drove off"
    #expect(merge(full, "the red car drove off slowly")
      == filler + " the red car drove off slowly")
  }

  @Test func aMatchOnlyEarlierThanTheLastEightyIsIgnored() {
    let filler = (1...100).map { "w\($0)" }.joined(separator: " ")
    let full = "alpha bravo charlie " + filler
    #expect(merge(full, "alpha bravo charlie delta") == full)
  }

  @Test func aBlankTailKeepsFull() {
    #expect(merge("the plan", "  \n ") == "the plan")
  }
}
