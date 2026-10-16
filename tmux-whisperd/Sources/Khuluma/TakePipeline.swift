import AppKit
import Foundation
import KhulumaCore

/// Transcribes, cleans up, delivers and persists one take: natively (daemon
/// socket + Swift cleanup) or through the CLI's `inline process`. Runs on
/// the controller's work queue; every call is synchronous and touches no UI.
final class TakePipeline {
  enum NativeRoute {
    case handled(TakeResult)
    /// Nothing visible happened: the take goes through the CLI instead.
    case fallback(String)
  }

  let cli: CLIBridge
  let persister: TakePersister
  /// Takes whose transcription timed out, for Retry/Discard.
  let timedOut = TimedOutTakes.standard
  /// The daemon didn't answer: the supervisor should look at it.
  private let onUnreachable: () -> Void

  init(cli: CLIBridge, persister: TakePersister, onUnreachable: @escaping () -> Void) {
    self.cli = cli
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
  func processNatively(samples: [Float], take: Take, recordMs: Int, appName: String?,
                       config: AppConfig, stopAt: Double) -> NativeRoute {
    guard let native = config.native else { return .fallback("transcription settings missing") }
    let (transcription, cleanup, modelPath) = native
    let takeId = UUID().uuidString.lowercased()
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

    let transcribed: NativeTranscriber.Result
    do {
      transcribed = try NativeTranscriber(settings: transcription, keepWAV: transcription.keepLogs)
        .transcribeTimed(samples: samples) { wav, flow in
        // Tag the take before its own request can count as contention.
        if flow == "inline" { _ = probeState() }
        return try client.transcribePass(wav: wav, language: transcription.language, flow: flow, modelPath: modelPath,
                                         modelVersion: transcription.modelVersion, timeout: timeout)
      }
    } catch let failure as NativeTranscriber.Failure {
      if case DaemonClient.ClientError.timedOut(let seconds) = failure.underlying {
        // Re-running through the CLI would wait on the same daemon again.
        // No automatic retry: keep the audio for an hour for Retry/Discard.
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
      Log.write("pipeline: native transcription unavailable (\(failure.underlying.localizedDescription)); using the CLI path")
      return .fallback(Self.fallbackReason(failure.underlying))
    } catch {
      Log.write("pipeline: native transcription unavailable (\(error.localizedDescription)); using the CLI path")
      return .fallback("native transcription failed")
    }
    let transcribedAt = monotonicMs()
    record.transcribeMs = Int(transcribedAt - startedAt)
    record.wavPath = transcribed.keptWAV?.path
    if transcribed.tailRescueFailed {
      Log.write("pipeline: tail rescue pass failed; kept the full transcript (as the CLI does)")
    }

    let outcome = TextPipeline(settings: cleanup).process(transcript: transcribed.transcript)
    let cleanedAt = monotonicMs()
    record.cleanMs = Int(cleanedAt - transcribedAt)

    switch outcome {
    case .needsCLI:
      if let kept = transcribed.keptWAV { try? FileManager.default.removeItem(at: kept) }
      return .fallback("cleanup needs the CLI")
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
        persister.persist(record)
        return .handled(.failed(error.localizedDescription))
      }
      let deliveredAt = monotonicMs()
      let deliveredDate = Date()
      record.delivered = true
      record.deliveredAtMs = Int(deliveredDate.timeIntervalSince1970 * 1000)
      record.deliveredLocalDate = LocalDate.string(for: deliveredDate)
      record.pasteMs = Int(deliveredAt - cleanedAt)
      record.totalMs = recordMs + Int(deliveredAt - stopAt)
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

  /// The CLI path: `tmux-whisper inline process` transcribes, cleans up and
  /// saves history; the app delivers, then records usage.
  func processWithCLI(samples: [Float], take: Take, recordMs: Int, appName: String?,
                      stopAt: Double, config: AppConfig?, route: (path: String, reason: String)) -> TakeResult {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let startedAt = monotonicMs()
    var processedAt: Double?
    func logTake(_ outcome: String, _ extra: (inout TakeLog) -> Void = { _ in }) {
      var line = TakeLog()
      line.add("path", route.path)
      line.add("reason", route.reason)
      line.add("outcome", outcome)
      line.add("record", recordMs)
      line.add("total", ms: monotonicMs() - stopAt)
      line.add("queue", ms: startedAt - stopAt)
      line.add("cli", ms: processedAt.map { $0 - startedAt })
      extra(&line)
      Log.write(line.line)
    }
    do {
      try WAVEncoder.encode(samples: samples).write(to: wav, options: [.atomic])
      chmod(wav.path, 0o600)
      let result = try cli.process(wav: wav, app: appName, recordMs: recordMs,
                                   startupMs: take.startupMs, startedAtEpochMs: take.startedEpochMs)
      processedAt = monotonicMs()
      guard result.ok else {
        logTake(result.status == "no_speech" ? "no_speech" : "failed") { line in
          if result.status != "no_speech" { line.add("error", TakeLog.cliStatus(result.status)) }
        }
        return result.status == "no_speech" ? .noSpeech : .failed(result.message ?? result.status)
      }
      // An invalid config.toml with no valid copy means default settings
      // (autosend on): paste without sending. Unknown settings count as that.
      let delivery = config.map { $0.safeDelivery(result.delivery) }
        ?? Delivery(autosend: false, sendMode: result.delivery.sendMode, pasteTarget: result.delivery.pasteTarget,
                    activateDelayMs: result.delivery.activateDelayMs, sendDelayMs: result.delivery.sendDelayMs)
      let steps = DeliveryPlan.steps(text: result.text, delivery: take.delivery(delivery),
                                     hasOriginalApp: take.originalApp != nil)
      let delivering = monotonicMs()
      let target = try Deliverer.perform(steps, originalApp: take.originalApp)
      if result.usageDeferred {
        // Count it now that the text is delivered (history and bench are
        // already saved by `inline process`).
        let deliveredDate = Date()
        var usage = TakeRecord(takeId: UUID().uuidString.lowercased(), status: "ok", delivered: true)
        usage.usageOnly = true
        usage.text = result.text
        usage.app = appName
        usage.recordMs = recordMs
        usage.totalMs = recordMs + Int(monotonicMs() - stopAt)
        usage.startupMs = take.startupMs
        usage.startedAtMs = take.startedEpochMs
        usage.deliveredAtMs = Int(deliveredDate.timeIntervalSince1970 * 1000)
        usage.deliveredLocalDate = LocalDate.string(for: deliveredDate)
        usage.startupSource = "app:avaudioengine"
        persister.persist(usage)
      }
      logTake("delivered") { line in
        line.add("transcribe", result.timings["transcribe_ms"])
        line.add("deliver", ms: monotonicMs() - delivering)
        line.add("waits", DeliveryPlan.waitMs(steps))
        line.add("chars", result.text.count)
        line.add("target", target ?? "-")
      }
      // `inline process` saved history itself.
      return .delivered(recorded: true)
    } catch {
      logTake("failed") { $0.add("error", Self.errorCategory(error)) }
      return .failed(error.localizedDescription)
    }
  }

  /// A short, stable reason for the take log (details go on the
  /// `pipeline:` line).
  private static func fallbackReason(_ error: Error) -> String {
    switch error as? DaemonClient.ClientError {
    case .unreachable?: return "daemon unreachable"
    case .protocolError?: return "daemon protocol error"
    case .daemon(let code, _)?: return "daemon error \(code)"
    case .timedOut?: return "daemon timed out"
    case nil: return "native transcription failed"
    }
  }

  /// A fixed error category for the take log: never the message, which
  /// can carry CLI output (and so dictated text).
  private static func errorCategory(_ error: Error) -> String {
    if error is AppContract.Mismatch { return "cli_mismatch" }
    if let bridge = error as? CLIBridge.BridgeError {
      switch bridge {
      case .notInstalled: return "cli_missing"
      case .failed: return "cli_failed"
      case .timedOut: return "cli_timed_out"
      case .badOutput: return "cli_bad_output"
      }
    }
    let error = error as NSError
    if error.domain == "Khuluma" {
      switch error.code {
      case 2: return "accessibility_missing"
      case 3: return "no_paste_key"
      case 4: return "target_is_self"
      default: return "app_\(error.code)"
      }
    }
    return "other"
  }
}
