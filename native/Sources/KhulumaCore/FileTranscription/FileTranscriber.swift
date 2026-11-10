import Foundation

/// One file, as `khuluma transcribe` does it: decode to a private 16 kHz WAV,
/// transcribe it (flow "file"), re-transcribe the last 8 s of files of 12 s or
/// more (flow "file-tail") and merge, then remove placeholder artefacts. The
/// raw transcript: no vocabulary, spelling, filler or LLM cleanup, and nothing
/// recorded in history or usage.
public struct FileTranscriber {
  /// Who transcribes a WAV: the app's daemon or the model loaded in-process.
  public struct Engine: Sendable {
    /// The JSON `engine` field ("swift_parakeet", as the CLI reports it).
    public let name: String
    /// The JSON `model` field (the model folder's name).
    public let model: String
    public let transcribe: @Sendable (_ wav: URL, _ flow: String, _ timeout: TimeInterval) throws -> String
    /// Send long files in bounded chunks (the daemon: one long request would
    /// hold its serial gate and keep dictation waiting).
    public var chunksLongFiles: Bool

    public init(name: String, model: String, chunksLongFiles: Bool = false,
                transcribe: @escaping @Sendable (_ wav: URL, _ flow: String, _ timeout: TimeInterval) throws -> String) {
      self.name = name
      self.model = model
      self.chunksLongFiles = chunksLongFiles
      self.transcribe = transcribe
    }
  }

  public struct Transcript: Equatable, Sendable {
    public let text: String
    public let audioDurationMs: Int
    public let processingMs: Int
    public let model: String
    public let engine: String
  }

  /// A file that failed; `message` follows `khuluma: ` as the CLI words it.
  public struct Failure: Error, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
  }

  public var tailRescueMs = 8000
  public var tailRescueMinMs = 12000
  /// The daemon socket's floor; long files get their own length.
  public var baseTimeout: TimeInterval = 600
  /// Called after decoding, before transcription (the CLI's progress line).
  public var onDecoded: (_ durationMs: Int) -> Void = { _ in }
  /// Chunked files: at most this many samples per request (60 s)...
  public var chunkSamples = 60 * AudioPrep.sampleRate
  /// ...cut at the quietest 20 ms in the last 5 s before that limit.
  public var cutSearchSamples = 5 * AudioPrep.sampleRate
  /// Right before every engine request (first pass, each chunk, the tail
  /// pass): the Quick Action waits here while a dictation take is recording
  /// or in flight, including one that started while the file was decoding.
  public var beforeRequest: () -> Void = {}

  public init() {}

  /// `label` names the file in messages. `workDirectory` is private and
  /// owned by the caller; the WAVs written there are removed before return.
  public func transcribe(_ input: URL, label: String, workDirectory: URL, engine: Engine) throws -> Transcript {
    let stem = "input-\(UUID().uuidString)"
    let wav = workDirectory.appendingPathComponent("\(stem).wav")
    let tailWAV = workDirectory.appendingPathComponent("\(stem)-tail.wav")
    defer {
      try? FileManager.default.removeItem(at: wav)
      try? FileManager.default.removeItem(at: tailWAV)
    }
    let decoded: AudioFileDecoder.Decoded
    do {
      decoded = try AudioFileDecoder.decode(input, to: wav)
    } catch AudioFileDecoder.DecodeError.noAudio {
      throw Failure("no audio found in: \(label)")
    } catch {
      throw Failure("could not decode audio: \(label) (\(error.localizedDescription))")
    }
    let durationMs = decoded.durationMs
    onDecoded(durationMs)
    let timeout = max(baseTimeout, TimeInterval(durationMs / 1000))

    let started = DispatchTime.now().uptimeNanoseconds
    let full: String
    do {
      if engine.chunksLongFiles && decoded.samples > chunkSamples {
        full = try transcribeChunks(decoded, workDirectory: workDirectory, stem: stem, engine: engine)
      } else {
        full = PerlText.bashCapture(try request(engine, wav, "file", timeout))
      }
    } catch {
      throw Failure("transcription failed: \(label) (\(error.localizedDescription))")
    }
    var text = full
    if let window = tailWindow(durationMs: durationMs) {
      // The CLI keeps the full transcript when the tail pass fails.
      if (try? AudioFileDecoder.writeTail(of: decoded, windowMs: window, to: tailWAV)) != nil,
         let tail = try? request(engine, tailWAV, "file-tail", timeout) {
        let spaced = PerlText.bashCapture(tail).replacingOccurrences(of: "\n", with: " ")
        if !PerlText.isBlank(spaced) {
          text = PerlText.bashCapture(TranscriptMerge.mergeTailAnchored(full: full, tail: spaced))
        }
      }
    }
    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    text = PerlText.bashCapture(TextCleanup.sanitizeArtifacts(text))
    guard !PerlText.isBlank(text) else { throw Failure("no speech detected in: \(label)") }
    return Transcript(text: text, audioDurationMs: durationMs, processingMs: elapsed,
                      model: engine.model, engine: engine.name)
  }

  private func request(_ engine: Engine, _ wav: URL, _ flow: String, _ timeout: TimeInterval) throws -> String {
    beforeRequest()
    return try engine.transcribe(wav, flow, timeout)
  }

  /// One request per chunk (each well inside the base timeout), texts
  /// joined with a space.
  private func transcribeChunks(_ decoded: AudioFileDecoder.Decoded, workDirectory: URL, stem: String,
                                engine: Engine) throws -> String {
    let reader = try WAVSampleReader(decoded)
    let cuts = Self.chunkCuts(total: decoded.samples, limit: chunkSamples, search: cutSearchSamples,
                              read: { try reader.samples($0) })
    var texts: [String] = []
    var start = 0
    for (index, end) in cuts.enumerated() {
      let url = workDirectory.appendingPathComponent("\(stem)-chunk\(index).wav")
      defer { try? FileManager.default.removeItem(at: url) }
      var pcm = try reader.samples(start..<end)
      if pcm.count < AudioFileDecoder.minimumSamples {
        pcm.append(contentsOf: repeatElement(0, count: AudioFileDecoder.minimumSamples - pcm.count))
      }
      try WAVEncoder.encode(pcm: pcm).write(to: url)
      let text = PerlText.bashCapture(try request(engine, url, "file", baseTimeout))
      if !PerlText.isBlank(text) { texts.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
      start = end
    }
    return texts.joined(separator: " ")
  }

  /// Chunk ends (exclusive sample indexes, the last = `total`): each chunk is
  /// at most `limit` samples, cut at the centre of the quietest 20 ms frame
  /// in the `search` samples before the limit, so words aren't split.
  static func chunkCuts(total: Int, limit: Int, search: Int,
                        read: (Range<Int>) throws -> [Int16]) -> [Int] {
    let frame = AudioPrep.sampleRate / 50
    var cuts: [Int] = []
    var start = 0
    while total - start > limit {
      let windowEnd = start + limit
      let windowStart = max(start + frame, windowEnd - search)
      var cut = windowEnd
      if let samples = try? read(windowStart..<windowEnd), samples.count >= frame {
        var best = Int64.max
        var offset = 0
        while offset + frame <= samples.count {
          var energy: Int64 = 0
          for sample in samples[offset..<(offset + frame)] { energy += Int64(sample) * Int64(sample) }
          // Ties go to the latest frame: longer chunks, fewer requests.
          if energy <= best { best = energy; cut = windowStart + offset + frame / 2 }
          offset += frame
        }
      }
      cuts.append(cut)
      start = cut
    }
    cuts.append(total)
    return cuts
  }

  /// `transcribe_swift_parakeet_tail_rescue_cli`'s window, or nil.
  func tailWindow(durationMs: Int) -> Int? {
    guard durationMs >= tailRescueMinMs else { return nil }
    let window = max(tailRescueMs, 1000)
    return durationMs > window + 1000 ? window : nil
  }

  /// `transcribe_file_format_duration`.
  public static func formatDuration(_ ms: Int) -> String {
    let total = (ms + 500) / 1000
    if total >= 3600 { return String(format: "%dh %02dm %02ds", total / 3600, total % 3600 / 60, total % 60) }
    if total >= 60 { return String(format: "%dm %02ds", total / 60, total % 60) }
    return "\(total)s"
  }
}

/// Which engine a file goes to.
public enum FileEngineChoice: Equatable, Sendable {
  /// The app's daemon answers and holds this model: send it the file.
  case daemon
  /// Load the model in this process.
  case inProcess
  /// No downloaded model anywhere.
  case noModel

  public static func choose(model: (path: String, version: String)?, daemon: DaemonStatus?) -> FileEngineChoice {
    guard let model else { return .noModel }
    if let daemon, daemon.holds(path: model.path, version: model.version) { return .daemon }
    return .inProcess
  }

  public static let noModelMessage = "speech model not downloaded yet; open Khuluma once to download it"
}

extension FileTranscriber.Engine {
  /// The app's own daemon (never the CLI's socket).
  public static func daemon(socketPath: String, modelPath: String, modelVersion: String, language: String) -> Self {
    let client = DaemonClient(socketPath: socketPath)
    return Self(name: "swift_parakeet", model: (modelPath as NSString).lastPathComponent,
                chunksLongFiles: true) { wav, flow, timeout in
      try client.transcribe(wav: wav, language: language, flow: flow, modelPath: modelPath,
                            modelVersion: modelVersion, timeout: timeout)
    }
  }
}
