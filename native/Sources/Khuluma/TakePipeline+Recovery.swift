import AppKit
import Foundation
import KhulumaCore

/// Takes saved to disk at Quit (or when the CLI changed under them) that
/// still need transcribing.
extension TakePipeline {
  /// Transcribes a saved take into history (status "recovered": no usage,
  /// nothing pasted) and optionally onto the clipboard, then deletes the
  /// audio. Leaves the audio for the next launch if it can't transcribe.
  func recover(url: URL, samples: [Float], takeId: String, startedEpochMs: Int?, startupMs: Int,
               app: String?, config: AppConfig?, copy: Bool, store: RecoveredTakes) {
    if config?.transcription.provider == "elevenlabs" {
      recoverWithCLI(url: url, samples: samples, takeId: takeId, startedEpochMs: startedEpochMs,
                     startupMs: startupMs, app: app, copy: copy, store: store)
      return
    }
    guard let native = config?.native else {
      Log.write("recover: \(url.lastPathComponent) kept for later (native pipeline unavailable)")
      return
    }
    let (transcription, cleanup, modelPath) = native
    let client = DaemonClient(socketPath: transcription.socketPath)
    let timeout = Self.timeout(transcription, sampleCount: samples.count)
    do {
      let transcribed = try NativeTranscriber(settings: transcription).transcribe(samples: samples) { wav, flow in
        try client.transcribe(wav: wav, language: transcription.language, flow: flow, modelPath: modelPath,
                              modelVersion: transcription.modelVersion, timeout: timeout)
      }
      var record = TakeRecord(takeId: takeId, status: "recovered", delivered: false)
      record.app = app
      record.model = transcription.modelLabel
      record.recordMs = samples.count * 1000 / AudioPrep.sampleRate
      record.startupMs = startupMs
      record.startedAtMs = startedEpochMs
      record.captureWavMs = AudioPrep.ffprobeDurationMs(sampleCount: samples.count)
      record.captureWavBytes = 44 + 2 * samples.count
      switch TextPipeline(settings: cleanup).process(transcript: transcribed.transcript) {
      case .text(let raw, let text):
        record.rawText = raw
        record.text = text
        if copy {
          DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          }
        }
        Log.write("recover: \(url.lastPathComponent) transcribed (\(text.count) chars)" + (copy ? ", copied to the clipboard" : ""))
      case .noSpeech:
        record.status = "no_speech"
        Log.write("recover: \(url.lastPathComponent) had no speech")
      case .needsCLI:
        Log.write("recover: \(url.lastPathComponent) kept for later (settings need the CLI)")
        return
      }
      if persister.persist(record) {
        store.remove(url)
      } else {
        Log.write("recover: \(url.lastPathComponent) kept: its record could not be spooled")
      }
    } catch {
      Log.write("recover: \(url.lastPathComponent) kept for later: \(error.localizedDescription)")
    }
  }

  /// The opt-in cloud route uses the CLI's matching cleanup/history writer.
  /// It never pastes or counts a delivery; keep the original until history
  /// confirms the recovered transcript is durable.
  private func recoverWithCLI(url: URL, samples: [Float], takeId: String, startedEpochMs: Int?, startupMs: Int,
                              app: String?, copy: Bool, store: RecoveredTakes) {
    do {
      let result = try cli.process(wav: url, app: app, recordMs: samples.count * 1000 / AudioPrep.sampleRate,
                                   startupMs: startupMs, startedAtEpochMs: startedEpochMs ?? 0,
                                   expectedProvider: "elevenlabs")
      if result.status == "no_speech" {
        var record = TakeRecord(takeId: takeId, status: "no_speech", delivered: false)
        record.app = app
        record.model = "scribe_v2"
        record.recordMs = samples.count * 1000 / AudioPrep.sampleRate
        record.startupMs = startupMs
        record.startedAtMs = startedEpochMs
        // As on the native path, a durable no-speech result settles the
        // saved take without creating transcript history or usage.
        if persister.persist(record) {
          store.remove(url)
          Log.write("recover: \(url.lastPathComponent) had no speech")
        }
        return
      }
      guard result.ok, result.historySaved else {
        Log.write("recover: \(url.lastPathComponent) kept for later (transcription or history save incomplete)")
        return
      }
      if copy {
        DispatchQueue.main.sync {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(result.text, forType: .string)
        }
      }
      store.remove(url)
      Log.write("recover: \(url.lastPathComponent) saved to history using ElevenLabs Scribe")
    } catch {
      Log.write("recover: \(url.lastPathComponent) kept for later: \(error.localizedDescription)")
    }
  }
}
