import Foundation
import Testing
@testable import KhulumaCore

/// LiveSession: segment transcriptions queued while a take records, joined
/// at finish. Synthetic audio as in PauseSegmenterTests.
struct LiveSessionTests {
  private func sine(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.2 * sin(2.0 * .pi * 440.0 * Double($0) / 16_000.0)) }
  }
  private func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

  private func session(
    transcribe: @escaping @Sendable ([Float]) throws -> LiveSession.SegmentResult = { samples in
      .init(text: "seg", wordSpansMs: [[0, 100]], asrMs: 7)
    }
  ) -> LiveSession {
    var config = PauseSegmenter.Config()
    config.minSegmentMs = 1_000
    config.maxSegmentMs = 30_000
    config.pauseMs = 360
    return LiveSession(config: config, transcribe: transcribe)
  }

  /// 13 s speech + 0.5 s silence + 13 s speech + 0.5 s silence → two
  /// unforced cuts (pauses at 13 s and 26.5 s).
  private var twoPauseAudio: [Float] {
    sine(seconds: 13) + silence(seconds: 0.5) + sine(seconds: 13) + silence(seconds: 0.5) + sine(seconds: 1)
  }

  @Test func twoCutsGiveTwoPartsInOrder() throws {
    let session = session()
    session.feed(twoPauseAudio)
    let prefix = try session.finish(timeout: 10).get()
    #expect(prefix.segments == 2 && prefix.forced == 0)
    #expect(prefix.parts.count == 2)
    // Cut at the middle of each pause's first 360 ms: 13.18 s and 26.68 s.
    #expect(prefix.parts[0].startMs == 0)
    #expect(abs(prefix.parts[1].startMs - 13_180) <= 10)
    #expect(prefix.coveredSamples == 26_680 * 16)
    #expect(prefix.asrMs == 14)
  }

  @Test func noCutIsNoneCut() {
    let session = session()
    session.feed(sine(seconds: 5))
    guard case .failure(let reason) = session.finish(timeout: 5) else {
      Issue.record("expected a failure"); return
    }
    #expect(reason == .none_cut)
  }

  @Test func aThrowingSegmentFailsAndSkipsTheRest() throws {
    let calls = Calls()
    let session = session { samples in
      calls.add()
      if calls.count == 1 { throw NSError(domain: "x", code: 1) }
      return .init(text: "seg", wordSpansMs: nil, asrMs: 1)
    }
    session.feed(twoPauseAudio)
    guard case .failure(let reason) = session.finish(timeout: 5) else {
      Issue.record("expected a failure"); return
    }
    #expect(reason == .failed)
    #expect(calls.count == 1)
  }

  @Test func aSlowClosureTimesOut() {
    let session = session { _ in
      Thread.sleep(forTimeInterval: 30)
      return .init(text: "seg", wordSpansMs: nil, asrMs: 0)
    }
    session.feed(twoPauseAudio)
    guard case .failure(let reason) = session.finish(timeout: 0.3) else {
      Issue.record("expected a failure"); return
    }
    #expect(reason == .timed_out)
  }

  @Test func cancelWins() {
    let session = session()
    session.feed(twoPauseAudio)
    session.cancel()
    guard case .failure(let reason) = session.finish(timeout: 5) else {
      Issue.record("expected a failure"); return
    }
    #expect(reason == .cancelled)
  }

  @Test func chunkSizeDoesNotChangeTheOutcome() throws {
    let whole = session()
    whole.feed(twoPauseAudio)
    let chunked = session()
    for slice in stride(from: 0, to: twoPauseAudio.count, by: 4_000) {
      chunked.feed(Array(twoPauseAudio[slice..<min(slice + 4_000, twoPauseAudio.count)]))
    }
    let a = try whole.finish(timeout: 10).get()
    let b = try chunked.finish(timeout: 10).get()
    #expect(a.coveredSamples == b.coveredSamples && a.segments == b.segments)
    #expect(a.parts.map(\.startMs) == b.parts.map(\.startMs))
  }
}

/// Mutable counter for calls from @Sendable closures.
private final class Calls: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var count = 0
  func add() { lock.withLock { count += 1 } }
}
