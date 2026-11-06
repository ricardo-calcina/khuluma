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

    public init(name: String, model: String,
                transcribe: @escaping @Sendable (_ wav: URL, _ flow: String, _ timeout: TimeInterval) throws -> String) {
      self.name = name
      self.model = model
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
      full = PerlText.bashCapture(try engine.transcribe(wav, "file", timeout))
    } catch {
      throw Failure("transcription failed: \(label) (\(error.localizedDescription))")
    }
    var text = full
    if let window = tailWindow(durationMs: durationMs) {
      // The CLI keeps the full transcript when the tail pass fails.
      if (try? AudioFileDecoder.writeTail(of: decoded, windowMs: window, to: tailWAV)) != nil,
         let tail = try? engine.transcribe(tailWAV, "file-tail", timeout) {
        let spaced = PerlText.bashCapture(tail).replacingOccurrences(of: "\n", with: " ")
        if !PerlText.isBlank(spaced) {
          text = PerlText.bashCapture(TranscriptMerge.mergeTailRescue(full: full, tail: spaced))
        }
      }
    }
    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    text = PerlText.bashCapture(TextCleanup.sanitizeArtifacts(text))
    guard !PerlText.isBlank(text) else { throw Failure("no speech detected in: \(label)") }
    return Transcript(text: text, audioDurationMs: durationMs, processingMs: elapsed,
                      model: engine.model, engine: engine.name)
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
    return Self(name: "swift_parakeet", model: (modelPath as NSString).lastPathComponent) { wav, flow, timeout in
      try client.transcribe(wav: wav, language: language, flow: flow, modelPath: modelPath,
                            modelVersion: modelVersion, timeout: timeout)
    }
  }
}
