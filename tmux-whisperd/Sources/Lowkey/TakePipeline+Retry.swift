import Foundation
import LowkeyCore

/// A retried take's text, waiting for the user to paste it.
struct RetriedText {
  let entry: TimedOutTakes.Entry
  let text: String
  /// The native path's record, persisted once the text is pasted (the CLI
  /// path's `inline process` has already recorded the take).
  let record: TakeRecord?
}

enum RetryOutcome {
  case ready(RetriedText)
  case noSpeech
  case failed(String)
}

/// Retry for takes whose transcription timed out.
extension TakePipeline {
  /// Transcribes a kept take again: natively when the daemon holds the model
  /// now, else through `inline process`. Nothing is pasted here.
  func retranscribe(_ entry: TimedOutTakes.Entry) -> RetryOutcome {
    let info = entry.info
    let startedAt = monotonicMs()
    let config: AppConfig
    do {
      config = try cli.appConfig()
    } catch {
      return .failed("retry: cannot read settings: \(error.localizedDescription)")
    }
    // Natively only if the daemon is warm now; otherwise the CLI starts it.
    guard let (transcription, cleanup, modelPath) = config.native,
          DaemonClient(socketPath: transcription.socketPath).status(timeout: 1)?
            .holds(path: modelPath, version: transcription.modelVersion ?? "v3") == true else {
      return retranscribeWithCLI(entry)
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
    // A new take id: the timed-out attempt is already recorded under the old one.
    var record = TakeRecord(takeId: UUID().uuidString.lowercased(), status: "ok", delivered: false)
    record.app = info.app
    record.model = transcription.modelLabel
    record.recordMs = info.recordMs
    record.startupMs = info.startupMs
    record.startedAtMs = info.startedAtMs
    record.captureWavMs = AudioPrep.ffprobeDurationMs(sampleCount: samples.count)
    record.captureWavBytes = 44 + 2 * samples.count
    record.transcribeMs = Int(monotonicMs() - startedAt)
    switch TextPipeline(settings: cleanup).process(transcript: transcript, app: info.app) {
    case .needsCLI:
      return retranscribeWithCLI(entry)
    case .noSpeech:
      record.status = "no_speech"
      persister.persist(record)
      timedOut.remove(entry)
      return .noSpeech
    case .text(let raw, let text, let mode):
      record.rawText = raw
      record.text = text
      record.mode = mode
      return .ready(RetriedText(entry: entry, text: text, record: record))
    }
  }

  /// `inline process` on the kept WAV (it records history itself; usage
  /// waits until the retried text is pasted).
  private func retranscribeWithCLI(_ entry: TimedOutTakes.Entry) -> RetryOutcome {
    let info = entry.info
    do {
      let result = try cli.process(wav: entry.wav, app: info.app, recordMs: info.recordMs,
                                   startupMs: info.startupMs, startedAtEpochMs: info.startedAtMs)
      guard result.ok else {
        if result.status == "no_speech" {
          timedOut.remove(entry)
          return .noSpeech
        }
        return .failed("retry failed (recording kept): \(result.message ?? result.status)")
      }
      var usage: TakeRecord?
      if result.usageDeferred {
        var record = TakeRecord(takeId: UUID().uuidString.lowercased(), status: "ok", delivered: false)
        record.usageOnly = true
        record.text = result.text
        record.mode = result.mode
        record.app = info.app
        record.recordMs = info.recordMs
        record.startupMs = info.startupMs
        record.startedAtMs = info.startedAtMs
        usage = record
      }
      return .ready(RetriedText(entry: entry, text: result.text, record: usage))
    } catch {
      return .failed("retry failed (recording kept): \(error.localizedDescription)")
    }
  }
}
