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
    guard let (transcription, cleanup, modelPath) = config.native else {
      return .failed("retry: can't transcribe yet (\(config.nativePipelineBlocker ?? "transcription settings missing")); recording kept")
    }
    // Only once the daemon is warm: a cold one would just time out again.
    guard DaemonClient(socketPath: transcription.socketPath).status(timeout: 1)?
            .holds(path: modelPath, version: transcription.modelVersion ?? "v3") == true else {
      onUnreachable()
      return .failed("retry: Parakeet isn't ready yet; recording kept, try again shortly")
    }
    let samples: [Float]
    do {
      samples = try RecoveredTakes.samples(at: entry.wav)
    } catch {
      return .failed("retry: the kept recording is unreadable")
    }
    let client = DaemonClient(socketPath: transcription.socketPath)
    let timeout = Self.timeout(transcription, sampleCount: samples.count)
    let transcript: String
    do {
      transcript = try NativeTranscriber(settings: transcription).transcribe(samples: samples) { wav, flow in
        try client.transcribe(wav: wav, language: transcription.language, flow: flow, modelPath: modelPath,
                              modelVersion: transcription.modelVersion, timeout: timeout)
      }.transcript
    } catch {
      return .failed("retry failed (recording kept): \(error.localizedDescription)")
    }
    // The timed-out take's own id (its failed-transcription record doesn't
    // count as recorded), so a repeated retry is recognised.
    var record = TakeRecord(takeId: info.takeId, status: "ok", delivered: false)
    record.app = info.app
    record.model = transcription.modelLabel
    record.recordMs = info.recordMs
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
