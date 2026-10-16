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
      switch TextPipeline(settings: cleanup).process(transcript: transcribed.transcript, app: app) {
      case .text(let raw, let text, let mode):
        record.rawText = raw
        record.text = text
        record.mode = mode
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
}
