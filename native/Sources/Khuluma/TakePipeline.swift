import AppKit
import Foundation
import KhulumaCore

/// Transcribes, cleans up, delivers and persists one take: through the app's
/// daemon socket + Swift cleanup (or ElevenLabs Scribe). Runs on the
/// controller's work queue; every call is synchronous and touches no UI.
final class TakePipeline {
  enum NativeRoute {
    case handled(TakeResult)
    /// Nothing visible happened and nothing was counted: the daemon or its
    /// model wasn't ready, or transcription failed. The caller keeps the
    /// take in recovered/ until the supervisor reports ready.
    case kept(KeptTake)
  }

  /// The ElevenLabs Scribe transport (the real network unless a test injects one).
  var scribe = ScribeClient()
  /// The current settings (settings.json).
  let loadConfig: () -> AppConfig
  let persister: TakePersister
  /// Takes whose transcription timed out, for Retry/Discard.
  let timedOut = TimedOutTakes.standard
  /// The daemon didn't answer: the supervisor should look at it.
  let onUnreachable: () -> Void

  init(persister: TakePersister, loadConfig: @escaping () -> AppConfig, onUnreachable: @escaping () -> Void) {
    self.loadConfig = loadConfig
    self.persister = persister
    self.onUnreachable = onUnreachable
  }

  /// How long a take waits, after WAV prep, for the ping that tags it
  /// warm/cold/contended before sending its own request.
  private static let probeWait: TimeInterval = 0.05

  /// Parakeet runs far faster than real time; allow a cold model load.
  static func timeout(_ transcription: TranscriptionSettings, sampleCount: Int) -> TimeInterval {
    min(transcription.maxTimeout, 30 + 2 * Double(sampleCount) / Double(AudioPrep.sampleRate))
  }

  /// The native path: transcribe through the daemon socket, clean up in
  /// Swift, deliver, then persist in the background.
  func processNatively(samples: [Float], take: Take, takeId: String, recordMs: Int, appName: String?,
                       config: AppConfig, stopAt: Double, live: LiveTake? = nil) -> NativeRoute {
    guard let native = config.native else {
      return .kept(KeptTake(reason: "transcription settings missing", category: "settings_missing"))
    }
    let (transcription, cleanup, modelPath) = native
    let startedAt = monotonicMs()

    let client = DaemonClient(socketPath: transcription.socketPath)
    let modelVersion = transcription.modelVersion ?? "v3"
    let probe = TakeProbe { client.status(timeout: DaemonSupervisor.probeTimeout) }
    let probeState = { probe.state(waiting: Self.probeWait, modelPath: modelPath, modelVersion: modelVersion) }
    // The take's one log line: transcript-free, for tools/khuluma-report.sh.
    func logTake(_ outcome: String, endedAt: Double, transcribed: NativeTranscriber.Result? = nil,
                 _ extra: (inout TakeLog) -> Void = { _ in }) {
      var line = TakeLog()
      line.add("path", "native")
      line.add("outcome", outcome)
      line.add("state", probeState().rawValue)
      line.add("record", recordMs)
      line.add("total", ms: endedAt - stopAt)
      line.add("queue", ms: startedAt - stopAt)
      if let timings = transcribed?.timings {
        line.add("prep", ms: timings.prepMs)
        line.add("probe", ms: probe.waitedMs)
        if let full = timings.pass("inline") {
          // The probe wait happens inside the first pass's timing.
          line.add("full", ms: full.elapsedMs - probe.waitedMs)
          line.add("full_daemon", full.daemonMs)
        }
        line.add("tail_window", transcribed?.tailRescueMs)
        if let tail = timings.pass("inline-tail") {
          line.add("tail", ms: tail.elapsedMs)
          line.add("tail_daemon", tail.daemonMs)
        }
        if transcribed?.tailRescueFailed == true { line.add("tail_failed", 1) }
      }
      if let livePrefix {
        line.add("live", "on")
        line.add("live_segments", livePrefix.segments)
        line.add("live_forced", livePrefix.forced)
        line.add("live_covered", livePrefix.coveredSamples * 1000 / AudioPrep.sampleRate)
        line.add("live_asr", livePrefix.asrMs)
      } else if live != nil {
        line.add("live", "fallback")
        if let liveReason { line.add("live_reason", liveReason) }
      }
      extra(&line)
      Log.write(line.line)
    }
    let timeout = Self.timeout(transcription, sampleCount: samples.count)
    var record = TakeRecord(takeId: takeId, status: "ok", delivered: false)
    record.app = appName
    record.model = transcription.modelLabel
    record.recordMs = recordMs
    record.startupMs = take.startupMs
    record.startedAtMs = take.startedEpochMs
    record.captureWavMs = AudioPrep.ffprobeDurationMs(sampleCount: samples.count)
    record.captureWavBytes = 44 + 2 * samples.count

    // "Transcribe while recording": the segments finished during capture
    // are already transcribed; only the still-open tail needs a pass, then
    // the texts are joined. Trusted only when the settings it was built
    // with still match.
    var livePrefix: LiveSession.Prefix?
    var liveReason: String?
    if let live {
      if live.transcription != transcription || live.modelPath != modelPath {
        liveReason = "settings_changed"
        live.session.cancel()
      } else {
        switch live.session.finish(timeout: 15) {
        case .success(let prefix):
          if prefix.coveredSamples <= samples.count {
            livePrefix = prefix
          } else {
            liveReason = LiveSession.Fallback.none_cut.rawValue
          }
        case .failure(let reason):
          liveReason = reason.rawValue
        }
      }
    }

    let transcribed: NativeTranscriber.Result
    do {
      if let livePrefix {
        let tail = Array(samples[livePrefix.coveredSamples...])
        let tailSpans = SpansBox()
        var tailResult: NativeTranscriber.Result?
        if !tail.isEmpty {
          tailResult = try NativeTranscriber(settings: transcription)
            .transcribeTimed(samples: tail) { wav, flow in
            // Tag the take before its own request can count as contention.
            if flow == "inline" { _ = probeState() }
            let pass = try client.transcribePass(wav: wav, language: transcription.language, flow: flow,
                                                 modelPath: modelPath,
                                                 modelVersion: transcription.modelVersion, timeout: timeout)
            if flow == "inline" { tailSpans.value = pass.wordSpansMs }
            return pass
          }
        }
        var parts = livePrefix.parts
        if let tailResult {
          parts.append(.init(text: tailResult.transcript, wordSpansMs: tailSpans.value,
                             startMs: livePrefix.coveredSamples * 1000 / AudioPrep.sampleRate))
        }
        let joined = LiveTranscript.join(parts)
        if var tailResult {
          tailResult.transcript = joined.text
          tailResult.speechMs = joined.wordSpansMs.flatMap { SpeechTime.speechMs(spans: $0) }
          transcribed = tailResult
        } else {
          transcribed = NativeTranscriber.Result(
            transcript: joined.text, captureSamples: samples.count, paddedSamples: samples.count,
            speechMs: joined.wordSpansMs.flatMap { SpeechTime.speechMs(spans: $0) })
        }
      } else {
        transcribed = try NativeTranscriber(settings: transcription, keepWAV: transcription.keepLogs)
          .transcribeTimed(samples: samples) { wav, flow in
          // Tag the take before its own request can count as contention.
          if flow == "inline" { _ = probeState() }
          return try client.transcribePass(wav: wav, language: transcription.language, flow: flow, modelPath: modelPath,
                                           modelVersion: transcription.modelVersion, timeout: timeout)
        }
      }
    } catch let failure as NativeTranscriber.Failure {
      if let reason = DaemonReadiness.notReadyReason(
        failure.underlying, modelPath: modelPath, modelVersion: transcription.modelVersion ?? "v3",
        statusAfter: { client.status(timeout: 1) }) {
        if let kept = failure.keptWAV { try? FileManager.default.removeItem(at: kept) }
        Log.write("pipeline: daemon not ready (\(reason): \(failure.underlying.localizedDescription)); keeping the take until it is")
        onUnreachable()
        return .kept(KeptTake(reason: reason, category: "daemon_not_ready"))
      }
      if case DaemonClient.ClientError.timedOut(let seconds) = failure.underlying {
        // No automatic retry (it would wait on the same daemon again): keep
        // the audio for an hour for Retry/Discard.
        record.status = "transcribe_failed"
        record.wavPath = failure.keptWAV?.path
        record.transcribeMs = Int(monotonicMs() - startedAt)
        record.totalMs = recordMs + Int(monotonicMs() - stopAt)
        persister.persist(record)
        let status = client.status(timeout: 1)
        Log.write("pipeline: transcription timed out after \(Int(seconds))s; daemon "
                  + (status.map { "still answers pings (generation \($0.generation ?? "?"), \($0.activeRequests ?? -1) in flight)" }
                     ?? "does not answer pings"))
        let saved: Bool
        do {
          try timedOut.save(samples: samples, info: TimedOutTakes.Info(
            takeId: takeId, app: appName, recordMs: recordMs, startupMs: take.startupMs,
            startedAtMs: take.startedEpochMs, generation: status?.generation))
          saved = true
        } catch {
          saved = false
          Log.write("pipeline: could not keep the timed-out take for Retry: \(error.localizedDescription)")
        }
        logTake("timed_out", endedAt: monotonicMs()) { line in
          line.add("asr", ms: monotonicMs() - startedAt)
          line.add("kept", saved ? 1 : 0)
        }
        return .handled(.timedOut("transcription timed out after \(Int(seconds))s" + (saved ? " (Retry in the menu)" : ""),
                                  kept: saved))
      }
      if case DaemonClient.ClientError.unreachable = failure.underlying { onUnreachable() }
      if let kept = failure.keptWAV { try? FileManager.default.removeItem(at: kept) }
      Log.write("pipeline: transcription failed (\(failure.underlying.localizedDescription)); keeping the take")
      return .kept(KeptTake.afterNativeFailure(failure.underlying))
    } catch {
      Log.write("pipeline: transcription failed (\(error.localizedDescription)); keeping the take")
      return .kept(KeptTake.afterNativeFailure(error))
    }
    let transcribedAt = monotonicMs()
    record.transcribeMs = Int(transcribedAt - startedAt)
    record.wavPath = transcribed.keptWAV?.path
    record.speechMs = transcribed.speechMs.map { min($0, recordMs) }
    if transcribed.tailRescueFailed {
      Log.write("pipeline: tail rescue pass failed; kept the full transcript")
    }

    let outcome = TextPipeline(settings: cleanup).process(transcript: transcribed.transcript)
    let cleanedAt = monotonicMs()
    record.cleanMs = Int(cleanedAt - transcribedAt)

    switch outcome {
    case .noSpeech:
      record.status = "no_speech"
      record.totalMs = recordMs + Int(monotonicMs() - stopAt)
      logTake("no_speech", endedAt: monotonicMs(), transcribed: transcribed) { line in
        line.add("asr", ms: transcribedAt - startedAt)
        line.add("clean", ms: cleanedAt - transcribedAt)
      }
      persister.persist(record)
      return .handled(.noSpeech)
    case .text(let raw, let text):
      record.rawText = raw
      record.text = text
      let steps = DeliveryPlan.steps(text: text, delivery: take.delivery(config.delivery),
                                     hasOriginalApp: take.originalApp != nil)
      let target: String?
      do {
        target = try Deliverer.perform(steps, originalApp: take.originalApp)
      } catch {
        record.status = "paste_failed"
        record.pasteMs = Int(monotonicMs() - cleanedAt)
        record.totalMs = recordMs + Int(monotonicMs() - stopAt)
        logTake("paste_failed", endedAt: monotonicMs(), transcribed: transcribed) { line in
          line.add("asr", ms: transcribedAt - startedAt)
          line.add("clean", ms: cleanedAt - transcribedAt)
          line.add("error", Self.errorCategory(error))
        }
        let recorded = persister.persist(record)
        return .handled(.pasteFailed(error.localizedDescription, recorded: recorded))
      }
      let deliveredAt = monotonicMs()
      let deliveredDate = Date()
      record.delivered = true
      record.deliveredAtMs = Int(deliveredDate.timeIntervalSince1970 * 1000)
      record.deliveredLocalDate = LocalDate.string(for: deliveredDate)
      record.pasteMs = Int(deliveredAt - cleanedAt)
      record.totalMs = recordMs + Int(deliveredAt - stopAt)
      // Live transcription kept no WAV of its own: the debug archive is the
      // whole take, padded exactly as NativeTranscriber would have written it.
      if livePrefix != nil, transcription.keepLogs {
        let wav = AppRuntimePaths.temporary.appendingPathComponent("khuluma-\(UUID().uuidString).wav")
        let pcm = AudioPrep.padded(WAVEncoder.pcm16(samples), tailPadMs: transcription.tailPad ?? 0)
        try? WAVEncoder.encode(pcm: pcm).write(to: wav)
        record.wavPath = wav.path
      }
      logTake("delivered", endedAt: deliveredAt, transcribed: transcribed) { line in
        line.add("asr", ms: transcribedAt - startedAt)
        line.add("clean", ms: cleanedAt - transcribedAt)
        line.add("deliver", ms: deliveredAt - cleanedAt)
        line.add("waits", DeliveryPlan.waitMs(steps))
        line.add("chars", text.count)
        line.add("target", target ?? "-")
      }
      return .handled(.delivered(recorded: persister.persist(record)))
    }
  }

  /// A fixed error category for the take log: never the message.
  private static func errorCategory(_ error: Error) -> String {
    let error = error as NSError
    if error.domain == "Khuluma" {
      switch error.code {
      case 2: return "accessibility_missing"
      case 5: return "postevent_missing"
      case 3: return "no_paste_key"
      case 4: return "target_is_self"
      default: return "app_\(error.code)"
      }
    }
    return "other"
  }
}
