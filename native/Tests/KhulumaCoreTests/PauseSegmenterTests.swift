import Foundation
import Testing
@testable import KhulumaCore

/// Pause-driven cutting of live audio (the KHULUMA_LIVE_SIMULATE experiment).
/// "Speech" is a 440 Hz sine at amplitude 0.2 (~-17 dB, well above threshold),
/// "silence" is zeros.
struct PauseSegmenterTests {
  private func sine(seconds: Double) -> [Float] {
    let count = Int(seconds * 16_000)
    return (0..<count).map { Float(0.2 * sin(2.0 * .pi * 440.0 * Double($0) / 16_000.0)) }
  }
  private func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }
  private func feed(_ audio: [Float], chunk: Int? = nil, config: PauseSegmenter.Config = .init())
    -> (cuts: [PauseSegmenter.Cut], openStart: Int) {
    var segmenter = PauseSegmenter(config: config)
    var cuts: [PauseSegmenter.Cut] = []
    if let chunk {
      var index = 0
      while index < audio.count {
        cuts.append(contentsOf: segmenter.feed(Array(audio[index..<min(index + chunk, audio.count)])))
        index += chunk
      }
    } else {
      cuts = segmenter.feed(audio)
    }
    return (cuts, segmenter.openStart)
  }

  @Test func aPauseAfterMinSegmentCutsAtItsMiddle() {
    // 14 s speech + 0.5 s silence + 5 s speech: the run reaches the 360 ms
    // pause at 14.36 s, so the cut is the middle of those first 360 ms:
    // frame-aligned 14.18 s.
    let audio = sine(seconds: 14) + silence(seconds: 0.5) + sine(seconds: 5)
    let (cuts, openStart) = feed(audio)
    #expect(cuts.count == 1)
    #expect(cuts[0].forced == false)
    #expect(abs(cuts[0].sample - 14_180 * 16) <= 10 * 16)
    #expect(openStart == cuts[0].sample)
  }

  @Test func aPauseBeforeMinSegmentCutsNothing() {
    let audio = sine(seconds: 5) + silence(seconds: 0.5) + sine(seconds: 5)
    let (cuts, _) = feed(audio)
    #expect(cuts.isEmpty)
  }

  @Test func aShortDipForcesACutAtTheQuietSpot() {
    // 40 s of speech with a 100 ms dip at 27 s: the forced cut lands in it.
    var audio = sine(seconds: 40)
    for i in 27 * 16_000..<27 * 16_000 + 1_600 { audio[i] = 0 }
    let (cuts, _) = feed(audio)
    #expect(cuts.count == 1)
    #expect(cuts[0].forced == true)
    #expect(abs(cuts[0].sample - 27_050 * 16) <= 100 * 16)
  }

  @Test func unbrokenSpeechForcesACutInsideTheSearchWindow() {
    let audio = sine(seconds: 31)
    let (cuts, _) = feed(audio)
    #expect(cuts.count == 1)
    #expect(cuts[0].forced == true)
    // The search looks back 5 s from 30 s: the cut sits in 25–30 s.
    #expect(cuts[0].sample >= 25 * 16_000)
    #expect(cuts[0].sample <= 30 * 16_000)
  }

  @Test func chunkSizeDoesNotChangeTheCuts() {
    let audio = sine(seconds: 14) + silence(seconds: 0.5) + sine(seconds: 18) + silence(seconds: 0.5) + sine(seconds: 5)
    let whole = feed(audio)
    let twoFifty = feed(audio, chunk: 4_000)
    let odd = feed(audio, chunk: 37)
    #expect(whole.cuts == twoFifty.cuts)
    #expect(whole.cuts == odd.cuts)
    #expect(whole.openStart == twoFifty.openStart)
    #expect(whole.openStart == odd.openStart)
  }

  @Test func aLongSilenceAfterACutDoesNotCutAgainInTheSameRun() {
    // 13 s speech, 2 s silence, 13 s speech, 0.5 s silence: the first pause
    // cuts once mid-silence; the continuing run gives no more; the second
    // pause cuts because its middle is ≥12 s past the first cut.
    let audio = sine(seconds: 13) + silence(seconds: 2) + sine(seconds: 13) + silence(seconds: 0.5) + sine(seconds: 1)
    let (cuts, _) = feed(audio)
    #expect(cuts.count == 2)
    #expect(cuts.allSatisfy { !$0.forced })
    #expect(abs(cuts[0].sample - 13_180 * 16) <= 10 * 16)
    // Silence restarts at 28 s; middle of its first 360 ms ≈ 28.18 s.
    #expect(abs(cuts[1].sample - 28_180 * 16) <= 10 * 16)
  }

  @Test func openStartTracksTheLastCut() {
    let audio = sine(seconds: 14) + silence(seconds: 0.5) + sine(seconds: 14) + silence(seconds: 0.5) + sine(seconds: 2)
    let (cuts, openStart) = feed(audio)
    #expect(cuts.count == 2)
    #expect(openStart == cuts.last!.sample)
  }
}

/// LiveTranscript.join: trimming, skipping and span shifting.
struct LiveTranscriptTests {
  typealias Part = LiveTranscript.Part

  @Test func joinsSkipsAndTrims() {
    let (text, _) = LiveTranscript.join([
      Part(text: " hello ", startMs: 0),
      Part(text: "  ", startMs: 5_000),
      Part(text: "world\n", startMs: 10_000),
    ])
    #expect(text == "hello world")
  }

  @Test func spansAreShiftedByStartMs() {
    let (text, spans) = LiveTranscript.join([
      Part(text: "one two", wordSpansMs: [[0, 300], [350, 800]], startMs: 0),
      Part(text: "three", wordSpansMs: [[0, 400]], startMs: 1_200),
    ])
    #expect(text == "one two three")
    #expect(spans == [[0, 300], [350, 800], [1_200, 1_600]])
  }

  @Test func nilSpansInANonEmptyPartNilTheJoin() {
    let (_, spans) = LiveTranscript.join([
      Part(text: "one", wordSpansMs: [[0, 100]], startMs: 0),
      Part(text: "two", startMs: 500),
    ])
    #expect(spans == nil)
  }

  @Test func emptyPartsDoNotNilTheJoin() {
    let (_, spans) = LiveTranscript.join([
      Part(text: "", startMs: 0),
      Part(text: "one", wordSpansMs: [[0, 100]], startMs: 500),
    ])
    #expect(spans == [[500, 600]])
  }
}
