import Foundation

/// "Transcribe while recording": feeds PauseSegmenter as capture arrives and
/// transcribes each finished segment on a serial queue in the background, so
/// at stop only the still-open tail is left. Keeps only the open segment's
/// samples. Value-free state is guarded by `lock`; the transcribe closure
/// runs on `queue`, one segment at a time.
public final class LiveSession: @unchecked Sendable {
  public struct SegmentResult: Sendable {
    public var text: String
    public var wordSpansMs: [[Int]]?
    /// Wall ms the pass took.
    public var asrMs: Int
    public init(text: String, wordSpansMs: [[Int]]?, asrMs: Int) {
      self.text = text
      self.wordSpansMs = wordSpansMs
      self.asrMs = asrMs
    }
  }

  /// The finished segments at `finish`: the take's audio up to the last cut.
  public struct Prefix: Sendable, Equatable {
    /// The last cut; the caller transcribes `samples[coveredSamples...]`.
    public let coveredSamples: Int
    public let parts: [LiveTranscript.Part]
    public let segments: Int
    public let forced: Int
    /// Sum of the segments' asrMs.
    public let asrMs: Int
  }

  public enum Fallback: String, Error, Sendable {
    case none_cut = "no_cut"
    case failed
    case timed_out = "timeout"
    case cancelled
  }

  private struct Segment: Sendable {
    let start: Int
    let samples: [Float]
    let forced: Bool
  }

  private let queue = DispatchQueue(label: "khuluma.live")
  private let lock = NSLock()
  private let transcribe: @Sendable (_ samples: [Float]) throws -> SegmentResult
  private var segmenter: PauseSegmenter
  /// Samples since the last cut — the only audio the session holds.
  private var open: [Float] = []
  private var fed = 0
  /// No more feed or work once finishing/cancelled.
  private var done = false
  private var failed = false
  private var cancelled = false
  private var parts: [LiveTranscript.Part] = []
  private var segments = 0
  private var forced = 0
  private var asrMs = 0

  public init(config: PauseSegmenter.Config,
              transcribe: @escaping @Sendable (_ samples: [Float]) throws -> SegmentResult) {
    self.segmenter = PauseSegmenter(config: config)
    self.transcribe = transcribe
  }

  /// Samples fed so far.
  public var samplesFed: Int {
    lock.withLock { fed }
  }

  /// New 16 kHz samples, in capture order, from one thread at a time. Each
  /// cut queues a segment transcription and drops its samples.
  public func feed(_ samples: [Float]) {
    var cuts: [(start: Int, segment: Segment)] = []
    lock.lock()
    guard !done else {
      lock.unlock()
      return
    }
    open.append(contentsOf: samples)
    fed += samples.count
    for cut in segmenter.feed(samples) {
      let start = fed - open.count
      let count = cut.sample - start
      guard count > 0, count <= open.count else { continue }
      cuts.append((start, Segment(start: start, samples: Array(open[..<count]), forced: cut.forced)))
      open.removeFirst(count)
    }
    let currentDone = done
    lock.unlock()
    for (_, segment) in cuts where !currentDone {
      enqueue(segment)
    }
  }

  private func enqueue(_ segment: Segment) {
    let transcribe = self.transcribe
    queue.async { [self] in
      lock.lock()
      // `done` (finish was called) must not skip segments already queued:
      // finish() waits on exactly these running to completion.
      if failed || cancelled {
        lock.unlock()
        return
      }
      segments += 1
      if segment.forced { forced += 1 }
      lock.unlock()
      do {
        let result = try transcribe(segment.samples)
        lock.lock()
        if !cancelled {
          parts.append(.init(text: result.text, wordSpansMs: result.wordSpansMs,
                             startMs: segment.start * 1000 / AudioPrep.sampleRate))
          asrMs += result.asrMs
        }
        lock.unlock()
      } catch {
        lock.lock()
        failed = true
        lock.unlock()
      }
    }
  }

  /// Waits up to `timeout` for the queued segments. `.success` only when at
  /// least one cut exists and every segment transcribed; otherwise the
  /// reason. Afterwards the session accepts nothing more.
  public func finish(timeout: TimeInterval) -> Result<Prefix, Fallback> {
    lock.lock()
    done = true
    if cancelled {
      lock.unlock()
      return .failure(.cancelled)
    }
    lock.unlock()
    let reached = DispatchSemaphore(value: 0)
    queue.async { reached.signal() }
    guard reached.wait(timeout: .now() + timeout) == .success else {
      lock.lock()
      done = true
      lock.unlock()
      return .failure(.timed_out)
    }
    lock.lock()
    defer { lock.unlock() }
    if cancelled { return .failure(.cancelled) }
    if failed { return .failure(.failed) }
    guard segments > 0 else { return .failure(.none_cut) }
    return .success(Prefix(coveredSamples: fed - open.count, parts: parts,
                           segments: segments, forced: forced, asrMs: asrMs))
  }

  /// Drops queued work; a segment already running may finish but is ignored.
  public func cancel() {
    lock.lock()
    cancelled = true
    done = true
    lock.unlock()
  }
}
