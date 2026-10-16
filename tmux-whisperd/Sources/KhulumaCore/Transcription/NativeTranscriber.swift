import Foundation

/// The CLI's inline transcription (`transcribe_audio` →
/// `transcribe_swift_parakeet_tail_rescue_cli`) without the CLI: pad, write a
/// 16-bit WAV, transcribe, and for long takes re-transcribe the last 8 s and
/// merge. Text goes through the same `$(...)` captures as in bash, so the
/// result is what `process_inline_recording` would hand to cleanup.
public struct NativeTranscriber: Sendable {
  /// Transcribes one WAV for a flow ("inline" or "inline-tail").
  public typealias Transcribe = @Sendable (_ wav: URL, _ flow: String) throws -> String
  /// `Transcribe`, also reporting the daemon's own time.
  public typealias TranscribePass = @Sendable (_ wav: URL, _ flow: String) throws -> Pass

  /// One daemon request's answer.
  public struct Pass: Equatable, Sendable {
    public let text: String
    /// The daemon's `duration_ms`: model time only (no model load, no wait
    /// behind other requests). Nil from daemons that don't report it.
    public let daemonMs: Int?

    public init(text: String, daemonMs: Int? = nil) {
      self.text = text
      self.daemonMs = daemonMs
    }
  }

  /// Where a transcription's time went, for the take log.
  public struct Timings: Equatable, Sendable {
    public struct PassTiming: Equatable, Sendable {
      public let flow: String
      /// Request sent → answer read (or failure), including the daemon's time.
      public let elapsedMs: Double
      public let daemonMs: Int?
    }

    /// Converting, padding and writing the WAVs.
    public var prepMs: Double = 0
    public var passes: [PassTiming] = []

    public func pass(_ flow: String) -> PassTiming? { passes.first { $0.flow == flow } }
  }

  public struct Result: Equatable, Sendable {
    public let transcript: String
    /// Sample count of the capture as recorded (before padding).
    public let captureSamples: Int
    public let paddedSamples: Int
    /// The tail window that was re-transcribed and merged, if any.
    public let tailRescueMs: Int?
    public let tailRescueFailed: Bool
    /// The padded WAV, kept only when `keepWAV` is set (for the CLI's debug
    /// archive); the caller owns and removes it.
    public var keptWAV: URL? = nil
    public var timings = Timings()
  }

  /// A failed transcription, with the padded WAV when `keepWAV` is set (for
  /// the debug archive of the failed take; the caller owns it).
  public struct Failure: Error {
    public let underlying: Error
    public let keptWAV: URL?
  }

  public let settings: TranscriptionSettings
  public let directory: URL
  /// Keep the padded WAV for `[debug] keep_logs` instead of deleting it.
  public var keepWAV: Bool

  public init(
    settings: TranscriptionSettings, directory: URL = FileManager.default.temporaryDirectory, keepWAV: Bool = false
  ) {
    self.settings = settings
    self.directory = directory
    self.keepWAV = keepWAV
  }

  public func transcribe(samples: [Float], using transcribeText: Transcribe) throws -> Result {
    try transcribeTimed(samples: samples, passes: { Pass(text: try transcribeText($0, $1)) })
  }

  public func transcribeTimed(samples: [Float], passes transcribe: TranscribePass) throws -> Result {
    var timings = Timings()
    var mark = Self.nowMs()
    func lap() -> Double {
      let now = Self.nowMs()
      defer { mark = now }
      return now - mark
    }
    /// One pass, timed whether it answers or throws.
    func run(_ url: URL, _ flow: String) throws -> String {
      _ = lap()
      do {
        let pass = try transcribe(url, flow)
        timings.passes.append(.init(flow: flow, elapsedMs: lap(), daemonMs: pass.daemonMs))
        return pass.text
      } catch {
        timings.passes.append(.init(flow: flow, elapsedMs: lap(), daemonMs: nil))
        throw error
      }
    }

    let pcm = WAVEncoder.pcm16(samples)
    let padded = AudioPrep.padded(pcm, tailPadMs: settings.tailPad ?? 0)
    let stem = "khuluma-\(UUID().uuidString)"
    let fullURL = directory.appendingPathComponent("\(stem).wav")
    try writeWAV(padded, to: fullURL)
    timings.prepMs += lap()
    let kept = keepWAV ? fullURL : nil
    defer {
      if !keepWAV { try? FileManager.default.removeItem(at: fullURL) }
    }

    let full: String
    do {
      full = PerlText.bashCapture(try run(fullURL, "inline"))
    } catch {
      throw Failure(underlying: error, keptWAV: kept)
    }
    guard let window = AudioPrep.tailRescueWindowMs(paddedSampleCount: padded.count, settings: settings) else {
      return Result(transcript: full, captureSamples: pcm.count, paddedSamples: padded.count,
                    tailRescueMs: nil, tailRescueFailed: false, keptWAV: kept, timings: timings)
    }

    let tailURL = directory.appendingPathComponent("\(stem)-tail.wav")
    defer { try? FileManager.default.removeItem(at: tailURL) }
    var tailText: String?
    do {
      _ = lap()
      try writeWAV(AudioPrep.tail(padded, windowMs: window), to: tailURL)
      timings.prepMs += lap()
      tailText = PerlText.bashCapture(try run(tailURL, "inline-tail"))
    } catch {
      // The CLI keeps the full transcript when the tail pass fails.
      tailText = nil
    }
    guard let tail = tailText else {
      return Result(transcript: full, captureSamples: pcm.count, paddedSamples: padded.count,
                    tailRescueMs: window, tailRescueFailed: true, keptWAV: kept, timings: timings)
    }
    let spaced = String(String.UnicodeScalarView(tail.unicodeScalars.map { $0 == "\n" ? " " : $0 }))
    let transcript = PerlText.isBlank(spaced)
      ? full
      : PerlText.bashCapture(TranscriptMerge.mergeTailRescue(full: full, tail: spaced))
    return Result(transcript: transcript, captureSamples: pcm.count, paddedSamples: padded.count,
                  tailRescueMs: window, tailRescueFailed: false, keptWAV: kept, timings: timings)
  }

  static func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
  }

  private func writeWAV(_ pcm: [Int16], to url: URL) throws {
    let data = WAVEncoder.encode(pcm: pcm)
    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
  }
}
