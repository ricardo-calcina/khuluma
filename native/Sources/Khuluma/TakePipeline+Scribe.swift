import AppKit
import Foundation
import KhulumaCore

/// ElevenLabs Scribe takes: `ScribeRoute` transcribes and
/// cleans up; this delivers and persists exactly as a Parakeet take does.
extension TakePipeline {
  /// A failure keeps the take (the caller saves the recording) and counts
  /// nothing: no record is persisted.
  func processWithScribe(samples: [Float], take: Take, takeId: String, recordMs: Int, appName: String?,
                         config: AppConfig, stopAt: Double) -> TakeResult {
    guard let (transcription, cleanup) = config.scribe else { return .failed("ElevenLabs Scribe is not selected") }
    // One identity: the in-flight audio's id is the record's take_id, so a
    // recovered copy of an already-recorded take is recognised.
    let startedAt = monotonicMs()
    func logTake(_ outcome: String, _ extra: (inout TakeLog) -> Void = { _ in }) {
      var line = TakeLog()
      line.add("path", "scribe")
      line.add("outcome", outcome)
      line.add("record", recordMs)
      line.add("total", ms: monotonicMs() - stopAt)
      line.add("queue", ms: startedAt - stopAt)
      extra(&line)
      Log.write(line.line)
    }
    let route = ScribeRoute(client: scribe, cleanup: cleanup, language: transcription.language,
                            keepWAV: transcription.keepLogs)
    switch route.run(samples: samples, takeId: takeId, app: appName, recordMs: recordMs,
                     startupMs: take.startupMs, startedAtMs: take.startedEpochMs) {
    case .failed(let message):
      // Fixed wording only: never the key or a response body.
      logTake("failed") { $0.add("error", "scribe") }
      return .failed(message)
    case .noSpeech(var record):
      record.totalMs = recordMs + Int(monotonicMs() - stopAt)
      logTake("no_speech") { $0.add("asr", ms: Double(record.transcribeMs)) }
      persister.persist(record)
      return .noSpeech
    case .text(let text, var record):
      let cleanedAt = monotonicMs()
      let steps = DeliveryPlan.steps(text: text, delivery: take.delivery(config.delivery),
                                     hasOriginalApp: take.originalApp != nil)
      let target: String?
      do {
        target = try Deliverer.perform(steps, originalApp: take.originalApp)
      } catch {
        record.status = "paste_failed"
        record.pasteMs = Int(monotonicMs() - cleanedAt)
        record.totalMs = recordMs + Int(monotonicMs() - stopAt)
        logTake("paste_failed") { $0.add("asr", ms: Double(record.transcribeMs)) }
        let recorded = persister.persist(record)
        return .pasteFailed(error.localizedDescription, recorded: recorded)
      }
      let deliveredAt = monotonicMs()
      let deliveredDate = Date()
      record.delivered = true
      record.deliveredAtMs = Int(deliveredDate.timeIntervalSince1970 * 1000)
      record.deliveredLocalDate = LocalDate.string(for: deliveredDate)
      record.pasteMs = Int(deliveredAt - cleanedAt)
      record.totalMs = recordMs + Int(deliveredAt - stopAt)
      logTake("delivered") { line in
        line.add("asr", ms: Double(record.transcribeMs))
        line.add("deliver", ms: deliveredAt - cleanedAt)
        line.add("waits", DeliveryPlan.waitMs(steps))
        line.add("chars", text.count)
        line.add("target", target ?? "-")
      }
      return .delivered(recorded: persister.persist(record))
    }
  }

  /// A saved take into history through Scribe (status "recovered": no usage,
  /// nothing pasted). The audio stays unless the record is durable.
  func recoverWithScribe(url: URL, samples: [Float], takeId: String, startedEpochMs: Int?, startupMs: Int,
                         app: String?, copy: Bool, store: RecoveredTakes, config: AppConfig) {
    guard let (transcription, cleanup) = config.scribe else { return }
    let route = ScribeRoute(client: scribe, cleanup: cleanup, language: transcription.language,
                            keepWAV: transcription.keepLogs)
    switch route.run(samples: samples, takeId: takeId, status: "recovered", app: app,
                     recordMs: samples.count * 1000 / AudioPrep.sampleRate, startupMs: startupMs,
                     startedAtMs: startedEpochMs) {
    case .failed(let message):
      Log.write("recover: \(url.lastPathComponent) kept for later: \(message)")
    case .noSpeech(let record):
      if persister.persist(record) {
        store.remove(url)
        Log.write("recover: \(url.lastPathComponent) had no speech")
      }
    case .text(let text, let record):
      if copy {
        DispatchQueue.main.sync {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      }
      if persister.persist(record) {
        store.remove(url)
        Log.write("recover: \(url.lastPathComponent) saved to history using ElevenLabs Scribe (\(text.count) chars)"
                  + (copy ? ", copied to the clipboard" : ""))
      } else {
        Log.write("recover: \(url.lastPathComponent) kept: its record could not be spooled")
      }
    }
  }

  /// Retry of a kept take through Scribe. Nothing is pasted here.
  func retranscribeWithScribe(_ entry: TimedOutTakes.Entry, config: AppConfig) -> RetryOutcome {
    guard let (transcription, cleanup) = config.scribe else { return .failed("retry: ElevenLabs Scribe is not selected") }
    let info = entry.info
    let samples: [Float]
    do {
      samples = try RecoveredTakes.samples(at: entry.wav)
    } catch {
      return .failed("retry: the kept recording is unreadable")
    }
    let route = ScribeRoute(client: scribe, cleanup: cleanup, language: transcription.language,
                            keepWAV: transcription.keepLogs)
    // The timed-out take's own id, stable across retries: a failed-transcription record
    // doesn't count as recorded, and a retry that was already saved is skipped in `retranscribe`.
    switch route.run(samples: samples, takeId: info.takeId, app: info.app,
                     recordMs: info.recordMs, startupMs: info.startupMs, startedAtMs: info.startedAtMs) {
    case .failed(let message):
      return .failed("retry failed (recording kept): \(message)")
    case .noSpeech(let record):
      persister.persist(record)
      timedOut.remove(entry)
      return .noSpeech
    case .text(let text, let record):
      return .ready(RetriedText(entry: entry, text: text, record: record))
    }
  }
}
