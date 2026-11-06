import Foundation

/// A take through ElevenLabs Scribe: the take's WAV, the
/// transport, then the same cleanup as Parakeet takes. Delivery and
/// persistence stay with the app, which fills in what only it knows.
public struct ScribeRoute: Sendable {
  public enum Outcome: Equatable, Sendable {
    /// Cleaned text to deliver. `record` is the take so far (not delivered).
    case text(String, TakeRecord)
    /// Nothing to say after cleanup; `record` is the no-speech record.
    case noSpeech(TakeRecord)
    /// The take is kept and nothing is counted: the CLI's wording, no record.
    case failed(String)
  }

  public let client: ScribeClient
  public let cleanup: CleanupSettings
  public let language: String
  /// Keep the WAV for the `[debug] keep_logs` archive (the recorder removes it).
  public let keepWAV: Bool
  public let directory: URL

  public init(client: ScribeClient = ScribeClient(), cleanup: CleanupSettings, language: String,
              keepWAV: Bool = false, directory: URL = AppRuntimePaths.temporary) {
    self.client = client
    self.cleanup = cleanup
    self.language = language
    self.keepWAV = keepWAV
    self.directory = directory
  }

  /// `status` is "ok" for a live take and "recovered" for a saved one.
  public func run(samples: [Float], takeId: String, status: String = "ok", app: String?, recordMs: Int,
                  startupMs: Int, startedAtMs: Int?) -> Outcome {
    let startedAt = Self.nowMs()
    let wav = directory.appendingPathComponent("khuluma-\(UUID().uuidString).wav")
    guard FileManager.default.createFile(atPath: wav.path, contents: WAVEncoder.encode(samples: samples),
                                         attributes: [.posixPermissions: 0o600]) else {
      return .failed(ScribeClient.Failure.fileMissing.localizedDescription)
    }
    var keep = false
    defer { if !keep { try? FileManager.default.removeItem(at: wav) } }

    let transcript: String
    let speechMs: Int?
    do {
      let answer = try client.transcribeMeasured(wav: wav, language: language)
      transcript = PerlText.bashCapture(answer.text)
      speechMs = answer.speechMs
    } catch let failure as ScribeClient.Failure {
      return .failed(failure.localizedDescription)
    } catch {
      return .failed(ScribeClient.Failure.couldNotComplete.localizedDescription)
    }
    let transcribedAt = Self.nowMs()

    var record = TakeRecord(takeId: takeId, status: status, delivered: false)
    record.app = app
    record.model = ScribeClient.model
    record.recordMs = recordMs
    record.speechMs = speechMs.map { min($0, recordMs) }
    record.startupMs = startupMs
    record.startedAtMs = startedAtMs
    record.captureWavMs = AudioPrep.ffprobeDurationMs(sampleCount: samples.count)
    record.captureWavBytes = 44 + 2 * samples.count
    record.transcribeMs = Int(transcribedAt - startedAt)
    if keepWAV { keep = true; record.wavPath = wav.path }

    let outcome = TextPipeline(settings: cleanup).process(transcript: transcript)
    record.cleanMs = Int(Self.nowMs() - transcribedAt)
    switch outcome {
    case .noSpeech:
      record.status = "no_speech"
      return .noSpeech(record)
    case .text(let raw, let text):
      record.rawText = raw
      record.text = text
      return .text(text, record)
    }
  }

  private static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
}
