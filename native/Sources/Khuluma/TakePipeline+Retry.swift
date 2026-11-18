import Foundation
import KhulumaCore

/// A retried take's text, waiting for the user to paste it.
struct RetriedText {
  let entry: TimedOutTakes.Entry
  let text: String
  /// The take's record, persisted once the text is pasted.
  let record: TakeRecord?
}

enum RetryOutcome {
  case ready(RetriedText)
  case noSpeech
  case failed(String)
}

/// Retry for takes whose transcription timed out.
extension TakePipeline {
  /// Transcribes a kept take again, once the daemon holds the model (else it
  /// stays for a later Retry). Nothing is pasted here.
  func retranscribe(_ entry: TimedOutTakes.Entry) -> RetryOutcome {
    let info = entry.info
    let startedAt = monotonicMs()
    let config = loadConfig()
    // The retried text was already saved (a crash after it was recorded but
    // before the recording was removed): settle the recording, don't redo it.
    if persister.isRecorded(takeId: info.takeId) {
      timedOut.remove(entry)
      return .failed("retry: this dictation was already saved to history; recording removed")
    }
    if config.scribe != nil { return retranscribeWithScribe(entry, config: config) }
    let kept: KeptTranscription
    switch transcribeKept(entry.wav, config: config) {
    case .success(let value): kept = value
    case .failure(.notConfigured(let why)):
      return .failed("retry: can't transcribe yet (\(why)); recording kept")
    case .failure(.notWarm):
      return .failed("retry: Parakeet isn't ready yet; recording kept, try again shortly")
    case .failure(.unreadable):
      return .failed("retry: the kept recording is unreadable")
    case .failure(.failed(let error)):
      return .failed("retry failed (recording kept): \(error.localizedDescription)")
    }
    let (transcription, cleanup, samples) = (kept.transcription, kept.cleanup, kept.samples)
    let (transcript, speechMs) = (kept.transcript, kept.speechMs)
    // The timed-out take's own id (its failed-transcription record doesn't
    // count as recorded), so a repeated retry is recognised.
    var record = TakeRecord(takeId: info.takeId, status: "ok", delivered: false)
    record.app = info.app
    record.model = transcription.modelLabel
    record.recordMs = info.recordMs
    record.speechMs = speechMs.map { min($0, info.recordMs) }
    record.startupMs = info.startupMs
    record.startedAtMs = info.startedAtMs
    record.captureWavMs = AudioPrep.ffprobeDurationMs(sampleCount: samples.count)
    record.captureWavBytes = 44 + 2 * samples.count
    record.transcribeMs = Int(monotonicMs() - startedAt)
    switch TextPipeline(settings: cleanup).process(transcript: transcript) {
    case .noSpeech:
      record.status = "no_speech"
      persister.persist(record)
      timedOut.remove(entry)
      return .noSpeech
    case .text(let raw, let text):
      record.rawText = raw
      record.text = text
      return .ready(RetriedText(entry: entry, text: text, record: record))
    }
  }
}

/// A kept WAV transcribed in one pass (shared by Retry and Transcribe again).
struct KeptTranscription {
  let transcription: TranscriptionSettings
  let cleanup: CleanupSettings
  let samples: [Float]
  let transcript: String
  let speechMs: Int?
}

enum KeptTranscriptionFailure: Error {
  case notConfigured(String)
  case notWarm
  case unreadable
  case failed(Error)
}

enum TranscribeAgainOutcome {
  case text(raw: String, processed: String)
  case noSpeech
  case failed(String)
}

extension TakePipeline {
  /// Transcribes a whole kept WAV through the warm daemon: one
  /// `transcribeTimed` pass over every sample, with the normal tail rescue.
  func transcribeKept(_ wav: URL, config: AppConfig) -> Result<KeptTranscription, KeptTranscriptionFailure> {
    guard let (transcription, cleanup, modelPath) = config.native else {
      return .failure(.notConfigured(config.nativePipelineBlocker ?? "transcription settings missing"))
    }
    // Only once the daemon is warm: a cold one would just time out.
    guard DaemonClient(socketPath: transcription.socketPath).status(timeout: 1)?
            .holds(path: modelPath, version: transcription.modelVersion ?? "v3") == true else {
      onUnreachable()
      return .failure(.notWarm)
    }
    let samples: [Float]
    do { samples = try RecoveredTakes.samples(at: wav) } catch { return .failure(.unreadable) }
    let client = DaemonClient(socketPath: transcription.socketPath)
    let timeout = Self.timeout(transcription, sampleCount: samples.count)
    do {
      let transcribed = try NativeTranscriber(settings: transcription).transcribeTimed(samples: samples) { wav, flow in
        try client.transcribePass(wav: wav, language: transcription.language, flow: flow, modelPath: modelPath,
                                  modelVersion: transcription.modelVersion, timeout: timeout)
      }
      return .success(KeptTranscription(transcription: transcription, cleanup: cleanup, samples: samples,
                                        transcript: transcribed.transcript, speechMs: transcribed.speechMs))
    } catch {
      return .failure(.failed(error))
    }
  }

  /// History's "Transcribe again": the kept WAV, cleaned with the current
  /// settings. Nothing is pasted or recorded here. Blocks; call off main.
  func transcribeAgain(_ wav: URL) -> TranscribeAgainOutcome {
    let config = loadConfig()
    switch transcribeKept(wav, config: config) {
    case .failure(.notConfigured):
      return .failed(config.scribe != nil ? "Needs the Parakeet model" : "Can't transcribe yet")
    case .failure(.notWarm): return .failed("Parakeet isn't ready; try again shortly")
    case .failure(.unreadable): return .failed("The recording is unreadable")
    case .failure(.failed): return .failed("Transcription failed")
    case .success(let kept):
      switch TextPipeline(settings: kept.cleanup).process(transcript: kept.transcript) {
      case .noSpeech: return .noSpeech
      case .text(let raw, let text): return .text(raw: raw, processed: text)
      }
    }
  }
}
