import AppKit
import Foundation
import LowkeyCore
import ServiceManagement

/// Menu-bar app: hotkey → chime + capture → transcription and cleanup →
/// paste/send. Takes go through the native pipeline (daemon socket + Swift
/// cleanup) unless the settings need the CLI's `inline process`.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private struct Take {
    let hotkeyAt: Double
    let startedAt: Double
    let startedEpochMs: Int
    let startupMs: Int
    let originalApp: NSRunningApplication?
    /// Settings read while recording, so each take uses what the CLI would
    /// use now (e.g. after `tmux-whisper autosend off`), not launch-time values.
    let settings: SettingsFetch?
    /// Published before capture starts and removed when the take ends, so
    /// the CLI never swaps the daemon out mid-take.
    let marker: TakeMarker?
    /// The start chime: played once, when capture is confirmed.
    let chime: OneShot
  }

  /// If no audio has arrived this long after the engine started, chime
  /// anyway (and log it) rather than leave the press unanswered.
  private static let chimeFallback: TimeInterval = 0.75

  /// `tmux-whisper app-config --json`, fetched in the background.
  final class SettingsFetch: @unchecked Sendable {
    private let done = DispatchGroup()
    private var config: AppConfig?
    private var failure: String?

    init(cli: CLIBridge, queue: DispatchQueue) {
      done.enter()
      queue.async {
        do {
          self.config = try cli.appConfig()
        } catch {
          self.failure = error.localizedDescription
        }
        self.done.leave()
      }
    }

    /// The fresh settings, or nil (with a reason) if they could not be read in time.
    func wait(timeout: TimeInterval) -> (AppConfig?, String?) {
      guard done.wait(timeout: .now() + timeout) == .success else { return (nil, "timed out reading settings") }
      return (config, failure)
    }
  }

  private enum Phase {
    case ready, recording, processing, error(String)
  }

  private var statusItem: NSStatusItem!
  private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private let hotkeyLine = NSMenuItem(title: "Hotkey: –", action: nil, keyEquivalent: "")
  private let configLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let recoveredLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let daemonLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let retryItem = NSMenuItem(title: "", action: #selector(retryTimedOut), keyEquivalent: "")
  private let pasteRetriedItem = NSMenuItem(title: "", action: #selector(pasteRetried), keyEquivalent: "")
  private let discardTimedOutItem = NSMenuItem(title: "Discard timed-out recording", action: #selector(discardTimedOut), keyEquivalent: "")
  private let cancelItem = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
  private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")

  private let recorder = AudioRecorder()
  private let sounds = SoundPlayer()
  private lazy var hotkey = HotkeyMonitor { [weak self] in self?.toggle() }
  /// Ctrl+Esc cancels a recording, as in the Raycast setup. Bound only while
  /// recording, so the combination stays free for other apps otherwise.
  private lazy var cancelHotkey = HotkeyMonitor(signature: 0x4C4B434E /* 'LKCN' */) { [weak self] in
    self?.cancelRecording()
  }
  private static let cancelKey = try! HotkeySpec.parse("ctrl+escape")
  /// One start at a time; a failed start never leaves its marker behind.
  private let starter = TakeStarter()
  private var cli: CLIBridge?
  private var config: AppConfig?
  private var take: Take?
  /// Set once Quit has begun: the hotkey no longer starts new takes.
  private var quitting = false
  private var processing = 0
  private var phase: Phase = .ready { didSet { refreshStatus() } }
  private let work = DispatchQueue(label: "lowkey.work", qos: .userInitiated)
  /// `inline record` runs here, after delivery, one take at a time.
  private let persistQueue = DispatchQueue(label: "lowkey.persist", qos: .utility)
  private let verifyQueue = DispatchQueue(label: "lowkey.verify", qos: .utility)
  private let pending = PendingRecords.standard
  private let recovered = RecoveredTakes.standard
  private var recoveryRunning = false
  private let settingsQueue = DispatchQueue(label: "lowkey.settings", qos: .userInitiated, attributes: .concurrent)
  /// Where take markers go: the CLI's processing dir.
  private var markerDirectory: String { config?.transcription?.processingDir ?? TakeMarker.defaultDirectory }
  /// Marker dirs already swept for a previous run's leftovers.
  private var sweptMarkerDirectories: Set<String> = []
  /// Keeps the daemon warm (3c); nil until the CLI is found.
  private var supervisor: DaemonSupervisor?
  /// Why supervision is off, as last logged ("" = on).
  private var supervisionNote: String?
  private var supervisedTarget: DaemonSupervisor.Target?
  /// A hotkey change read while a take was recording, applied when it ends.
  private var pendingHotkey: HotkeySpec?
  /// Takes whose transcription timed out, for Retry/Discard.
  private let timedOut = TimedOutTakes.standard
  private var retrying = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    sweepStaleMarkers()
    Log.write("launch: Lowkey \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
              + ", start at login \(Self.loginStatusText(SMAppService.mainApp.status))")

    recorder.prepare()
    recorder.onConfigurationChange = { [weak self] in self?.handleDeviceChange() }
    AudioRecorder.requestPermission { granted in
      if !granted { Log.write("permission: microphone denied") }
    }
    if !Deliverer.isTrusted(prompt: true) {
      Log.write("permission: accessibility not granted yet (prompted)")
    }

    guard let cli = CLIBridge.locate() else {
      phase = .error("tmux-whisper CLI not found")
      return
    }
    self.cli = cli
    supervisor = DaemonSupervisor(
      environment: DaemonSupervisor.Environment(
        probe: { path, timeout in DaemonClient(socketPath: path).status(timeout: timeout) },
        warmup: { try cli.warmup() },
        schedule: { delay, work in DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work) }),
      onChange: { [weak self] state, line in
        Log.write("supervisor: \(line)")
        DispatchQueue.main.async { self?.showDaemonState(state) }
      })
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.supervisor?.trigger(.wake) }
    reloadSettings()
    replayPendingRecords(cli: cli)
    refreshTimedOutItems()
  }

  /// Quit never discards a dictation. A take still recording is saved to
  /// disk at once, then transcribed into history and onto the clipboard
  /// (never pasted or sent: the app in front at quit time, e.g. the terminal
  /// running a rebuild, is not where it was meant to go). Queued takes and
  /// persistence get up to 30 s; whatever doesn't finish is recovered at the
  /// next launch (saved audio, spooled records).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateLater }
    if take != nil || !unsaved.isEmpty {
      guard saveRecordingForQuit() else {
        // Couldn't write the audio: stay open rather than lose a take. Only
        // the explicit "Discard … and quit" menu item gives it up.
        discardItem.title = "Discard \(unsaved.count) unsaved recording\(unsaved.count == 1 ? "" : "s") and quit"
        discardItem.isHidden = false
        fail("couldn't save \(unsaved.count) recording\(unsaved.count == 1 ? "" : "s") for quitting; Quit retries")
        return .terminateCancel
      }
    }
    return terminateAfterDraining()
  }

  @objc private func discardUnsavedAndQuit() {
    Log.write("quit: discarding \(unsaved.count) unsaved recording(s) at the user's request")
    unsaved.forEach { $0.marker?.remove() }
    unsaved.removeAll()
    discardItem.isHidden = true
    NSApp.terminate(nil)
  }

  private func terminateAfterDraining() -> NSApplication.TerminateReply {
    quitting = true
    let replied = DispatchSemaphore(value: 1)
    let reply = {
      guard replied.wait(timeout: .now()) == .success else { return }
      DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    work.async { [persistQueue] in
      persistQueue.async { reply() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
      Log.write("quit: pending work did not finish within 30s; quitting (saved audio and spooled takes are recovered at next launch)")
      reply()
    }
    return .terminateLater
  }

  /// A take stopped for Quit whose audio couldn't be written yet.
  private struct UnsavedTake {
    let samples: [Float]
    let takeId: String
    let startedEpochMs: Int
    let startupMs: Int
    let app: String?
    let marker: TakeMarker?
  }
  /// Every take stopped for Quit whose audio couldn't be written yet.
  private var unsaved: [UnsavedTake] = []
  private let discardItem = NSMenuItem(title: "", action: #selector(discardUnsavedAndQuit), keyEquivalent: "")

  /// Stops the take in progress for Quit and writes its audio (and any
  /// earlier unsaved takes) to the recovery folder before anything else,
  /// then queues transcriptions that only copy the text. Returns false if
  /// any audio couldn't be written; those takes stay in `unsaved`.
  private func saveRecordingForQuit() -> Bool {
    if let take {
      let samples = recorder.stop()
      self.take = nil
      if samples.isEmpty {
        take.marker?.remove()
      } else {
        take.marker?.update(.processing)
        unsaved.append(UnsavedTake(samples: samples, takeId: UUID().uuidString.lowercased(),
                                   startedEpochMs: take.startedEpochMs, startupMs: take.startupMs,
                                   app: take.originalApp?.localizedName, marker: take.marker))
      }
    }
    let config = self.config
    var stillUnsaved: [UnsavedTake] = []
    for pendingTake in unsaved {
      do {
        let url = try recovered.save(samples: pendingTake.samples, takeId: pendingTake.takeId)
        Log.write("quit: saved a recording (\(pendingTake.samples.count / AudioPrep.sampleRate)s) to \(url.lastPathComponent)")
        // Only the newest take goes onto the clipboard.
        let copy = pendingTake.takeId == unsaved.last?.takeId
        work.async { [weak self] in
          defer { pendingTake.marker?.remove() }
          self?.recover(url: url, samples: pendingTake.samples, takeId: pendingTake.takeId,
                        startedEpochMs: pendingTake.startedEpochMs, startupMs: pendingTake.startupMs,
                        app: pendingTake.app, config: config, copy: copy)
        }
      } catch {
        Log.write("quit: could not save a recording: \(error.localizedDescription)")
        stillUnsaved.append(pendingTake)
      }
    }
    unsaved = stillUnsaved
    if unsaved.isEmpty { discardItem.isHidden = true }
    return unsaved.isEmpty
  }

  /// Transcribes a saved take into history (status "recovered": no usage,
  /// nothing pasted) and optionally onto the clipboard, then deletes the
  /// audio. Leaves the audio for the next launch if it can't transcribe.
  private func recover(url: URL, samples: [Float], takeId: String, startedEpochMs: Int?, startupMs: Int,
                       app: String?, config: AppConfig?, copy: Bool) {
    guard let cli, let config, config.nativePipelineBlocker == nil,
          let transcription = config.transcription, let cleanup = config.cleanup,
          let modelPath = transcription.modelPath else {
      Log.write("recover: \(url.lastPathComponent) kept for later (native pipeline unavailable)")
      return
    }
    let client = DaemonClient(socketPath: transcription.socketPath)
    let timeout = min(transcription.maxTimeout, 30 + 2 * Double(samples.count) / Double(AudioPrep.sampleRate))
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
      if persist(record, cli: cli) {
        recovered.remove(url)
      } else {
        Log.write("recover: \(url.lastPathComponent) kept: its record could not be spooled")
      }
    } catch {
      Log.write("recover: \(url.lastPathComponent) kept for later: \(error.localizedDescription)")
    }
  }

  /// Takes saved at a previous quit that didn't finish: transcribe them into
  /// history (no clipboard: it may hold something newer) and say so.
  private func recoverLeftoverTakes(config: AppConfig) {
    let leftovers = recovered.all()
    guard !leftovers.isEmpty, !recoveryRunning else { return }
    guard config.nativePipelineBlocker == nil else {
      // Can't transcribe natively with these settings: say so, and retry
      // whenever usable settings arrive.
      showRecoveredLine("Saved dictations waiting (\(leftovers.count)): Show in Finder", action: true)
      return
    }
    recoveryRunning = true
    work.async { [weak self] in
      guard let self else { return }
      for url in leftovers {
        guard let samples = try? RecoveredTakes.samples(at: url) else {
          Log.write("recover: \(url.lastPathComponent) is unreadable; leaving it in place")
          continue
        }
        self.recover(url: url, samples: samples, takeId: RecoveredTakes.takeId(of: url), startedEpochMs: nil,
                     startupMs: 0, app: nil, config: config, copy: false)
      }
      let remaining = self.recovered.all().count
      let done = leftovers.count - remaining
      DispatchQueue.main.async {
        self.recoveryRunning = false
        if remaining > 0 {
          self.showRecoveredLine("Saved dictations waiting (\(remaining)): Show in Finder", action: true)
        } else if done > 0 {
          self.showRecoveredLine(
            "Recovered \(done) dictation\(done == 1 ? "" : "s") from the last quit (tmux-whisper history)", action: false)
        }
      }
    }
  }

  private func showRecoveredLine(_ title: String, action: Bool) {
    recoveredLine.title = title
    recoveredLine.isEnabled = action
    recoveredLine.action = action ? #selector(showRecoveredFolder) : nil
    recoveredLine.target = action ? self : nil
    recoveredLine.isHidden = false
  }

  @objc private func showRecoveredFolder() {
    NSWorkspace.shared.activateFileViewerSelecting(recovered.all())
  }

  // MARK: - Recording

  private func toggle() {
    let hotkeyAt = monotonicMs()
    if take == nil {
      guard !quitting else { return }
      guard !starter.isStarting else {
        Log.write("start: ignored a press while the microphone was still starting")
        return
      }
      startRecording(hotkeyAt: hotkeyAt)
    } else {
      stopRecording()
    }
  }

  private func startRecording(hotkeyAt: Double) {
    // The chime is the cue to speak, so it plays only once the first audio
    // buffer has arrived: words spoken at the chime are always captured.
    // (It used to play before the engine started, ~120 ms before capture.)
    let chime = OneShot()
    let sounds = self.sounds
    let playChime: (String) -> Void = { how in
      guard chime.fire() else { return }
      sounds.play(.start) { playMs in
        Log.write(String(format: "start: chime %@, hotkey→chime ≈ %.1fms (play() %.1fms)",
                         how, monotonicMs() - hotkeyAt, playMs))
      }
    }
    let original = NSWorkspace.shared.frontmostApplication
    let directory = markerDirectory
    let outcome = starter.start(marker: {
      let marker = TakeMarker.create(directory: directory, takeId: UUID().uuidString.lowercased(), phase: .recording)
      if marker == nil {
        // Recording matters more: without the marker an upgrade could restart
        // the daemon mid-take, which costs a slower (CLI) take, not the take.
        Log.write("markers: could not publish a take marker in \(directory); recording anyway")
      }
      return marker
    }, capture: { try recorder.start(onFirstAudio: { playChime("at first audio") }) })
    switch outcome {
    case .started(let engineMs, let marker):
      let startedAt = monotonicMs()
      take = Take(
        hotkeyAt: hotkeyAt,
        startedAt: startedAt,
        startedEpochMs: Int(Date().timeIntervalSince1970 * 1000),
        startupMs: Int((startedAt - hotkeyAt).rounded()),
        originalApp: original,
        settings: cli.map { SettingsFetch(cli: $0, queue: settingsQueue) },
        marker: marker,
        chime: chime
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.chimeFallback) {
        playChime("with no audio yet after \(Int(Self.chimeFallback * 1000))ms")
      }
      phase = .recording
      do {
        // A toggle bound to the same keys already stops the take.
        if hotkey.binding != Self.cancelKey { try cancelHotkey.register(Self.cancelKey) }
      } catch {
        Log.write("hotkey: \(Self.cancelKey.display) to cancel is unavailable this take: \(error.localizedDescription)")
      }
      Log.write(String(format: "start: engine.start %.1fms, hotkey→capturing %.1fms, app=%@",
                       engineMs, startedAt - hotkeyAt, original?.localizedName ?? "-"))
      // While you speak: make sure the daemon is up with the model loaded
      // (a ping when it is; the CLI's warmup when it isn't).
      supervisor?.trigger(.recordingStart)
    case .busy:
      Log.write("start: ignored a press while the microphone was still starting")
    case .failed(let error):
      // The marker is already gone, so the CLI's idle check isn't blocked.
      chime.cancel()
      sounds.play(.error)
      fail("could not start recording: \(error.localizedDescription)")
    }
  }

  private func stopRecording() {
    guard let take else { return }
    // "Stop → delivered" starts here, before the engine is torn down.
    let stopAt = monotonicMs()
    take.chime.cancel()
    cancelHotkey.unregister()
    let firstBuffer = recorder.firstBufferTime
    let samples = recorder.stop()
    let engineStopMs = monotonicMs() - stopAt
    self.take = nil
    let recordMs = Int((stopAt - take.startedAt).rounded())
    if let firstBuffer {
      Log.write(String(format: "stop: record %dms, hotkey→first audio %.1fms, samples %d, capture stop %.1fms",
                       recordMs, firstBuffer - take.hotkeyAt, samples.count, engineStopMs))
    }
    guard !samples.isEmpty else {
      take.marker?.remove()
      applyPendingHotkey()
      sounds.play(.error)
      var line = TakeLog()
      line.add("path", "none")
      line.add("outcome", "no_audio")
      line.add("record", recordMs)
      Log.write(line.line)
      fail("no audio captured (microphone permission?)")
      return
    }
    take.marker?.update(.queued)
    applyPendingHotkey()
    if config?.inline.processSound ?? true {
      sounds.play(.process)
    }
    processing += 1
    phase = .processing
    process(samples: samples, take: take, recordMs: recordMs, stopAt: stopAt)
  }

  @objc private func cancelRecording() {
    guard let take else { return }
    take.chime.cancel()
    cancelHotkey.unregister()
    _ = recorder.stop()
    take.marker?.remove()
    self.take = nil
    sounds.play(.cancel)
    phase = processing > 0 ? .processing : .ready
    Log.write("cancel: recording discarded")
    applyPendingHotkey()
  }

  private func handleDeviceChange() {
    guard take != nil else { return }
    // The engine stops on a device switch; keep what was captured so far.
    Log.write("audio: device changed mid-recording; stopping the take")
    stopRecording()
  }

  // MARK: - Processing and delivery

  private func process(samples: [Float], take: Take, recordMs: Int, stopAt: Double) {
    guard let cli else {
      take.marker?.remove()
      var line = TakeLog()
      line.add("path", "none")
      line.add("outcome", "failed")
      line.add("record", recordMs)
      line.add("error", "cli_missing")
      Log.write(line.line)
      finishProcessing(error: "tmux-whisper CLI not found")
      return
    }
    let frontmostAtStop = NSWorkspace.shared.frontmostApplication?.localizedName
    let cachedConfig = self.config
    work.async { [weak self] in
      // Every path below is synchronous on this queue: the take is over when it returns.
      defer { take.marker?.remove() }
      guard let self else { return }
      take.marker?.update(.processing)
      // Settings fetched during the recording; usually ready long before
      // stop. Without them, the CLI path reads its own fresh settings.
      let (fresh, problem) = take.settings?.wait(timeout: 5) ?? (nil, "no settings fetch")
      if let fresh, fresh != cachedConfig {
        DispatchQueue.main.async { self.adopt(fresh) }
      }
      let config = fresh ?? cachedConfig
      // Match the CLI: "restore" uses the app from recording start; "current"
      // uses whatever is frontmost when processing begins (for mode detection).
      let appName = config?.inline.pasteTarget == "restore" ? take.originalApp?.localizedName : frontmostAtStop
      // How the take reaches the CLI path, for the take log.
      let route: (path: String, reason: String)
      if let fresh {
        if let blocker = fresh.nativePipelineBlocker {
          route = ("cli", blocker)
        } else {
          switch self.processNatively(samples: samples, take: take, recordMs: recordMs, appName: appName,
                                      config: fresh, cli: cli, stopAt: stopAt) {
          case .handled: return
          case .fallback(let reason): route = ("fallback", reason)
          }
        }
      } else {
        Log.write("pipeline: CLI path (\(problem ?? "settings unavailable"))")
        route = ("cli", problem ?? "settings unavailable")
      }
      take.marker?.update(.cli)
      self.processWithCLI(samples: samples, take: take, recordMs: recordMs, appName: appName, cli: cli,
                          stopAt: stopAt, config: config, route: route)
    }
  }

  private func sweepStaleMarkers() {
    let directory = markerDirectory
    guard sweptMarkerDirectories.insert(directory).inserted else { return }
    for name in TakeMarker.removeStale(directory: directory) {
      Log.write("markers: removed \(name), left by a previous run")
    }
  }

  /// Takes on settings read for a take: everything except re-registering an
  /// unchanged hotkey, which could drop a press while recording.
  private func adopt(_ fresh: AppConfig) {
    if fresh.hotkey != config?.hotkey {
      apply(fresh)
      return
    }
    let pipelineChanged = fresh.nativePipelineBlocker != config?.nativePipelineBlocker
    if fresh.config != config?.config { showConfigStatus(fresh) }
    recoverLeftoverTakes(config: fresh)
    config = fresh
    sweepStaleMarkers()
    configureSupervision(fresh, trigger: .settings)
    sounds.load(from: fresh)
    if pipelineChanged {
      Log.write("settings: pipeline " + (fresh.nativePipelineBlocker.map { "CLI (\($0))" } ?? "native"))
    }
  }

  private enum NativeRoute {
    case handled
    /// Nothing visible happened: the take goes through the CLI instead.
    case fallback(String)
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
    if let bridge = error as? CLIBridge.BridgeError {
      switch bridge {
      case .notInstalled: return "cli_missing"
      case .failed: return "cli_failed"
      case .timedOut: return "cli_timed_out"
      case .badOutput: return "cli_bad_output"
      }
    }
    let error = error as NSError
    if error.domain == "Lowkey" {
      switch error.code {
      case 2: return "accessibility_missing"
      case 3: return "no_paste_key"
      default: return "lowkey_\(error.code)"
      }
    }
    return "other"
  }

  /// How long a take waits, after WAV prep, for the ping that tags it
  /// warm/cold/contended before sending its own request.
  private static let probeWait: TimeInterval = 0.05

  /// Phase 3b: transcribe through the daemon socket, clean up in Swift,
  /// deliver, then persist in the background.
  private func processNatively(samples: [Float], take: Take, recordMs: Int, appName: String?,
                               config: AppConfig, cli: CLIBridge, stopAt: Double) -> NativeRoute {
    guard let transcription = config.transcription, let cleanup = config.cleanup,
          let modelPath = transcription.modelPath else { return .fallback("transcription settings missing") }
    let takeId = UUID().uuidString.lowercased()
    let startedAt = monotonicMs()

    let client = DaemonClient(socketPath: transcription.socketPath)
    let modelVersion = transcription.modelVersion ?? "v3"
    let probe = TakeProbe { client.status(timeout: DaemonSupervisor.probeTimeout) }
    let probeState = { probe.state(waiting: Self.probeWait, modelPath: modelPath, modelVersion: modelVersion) }
    // The take's one log line: transcript-free, for tools/lowkey-report.sh.
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
    // Parakeet runs far faster than real time; allow a cold model load.
    let timeout = min(transcription.maxTimeout, 30 + 2 * Double(samples.count) / Double(AudioPrep.sampleRate))
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
        persist(record, cli: cli)
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
        DispatchQueue.main.async {
          self.sounds.play(.error)
          self.refreshTimedOutItems()
          self.finishProcessing(error: "transcription timed out after \(Int(seconds))s"
                                + (saved ? " (Retry in the menu)" : ""))
        }
        return .handled
      }
      if case DaemonClient.ClientError.unreachable = failure.underlying { supervisor?.trigger(.unreachable) }
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

    let outcome = TextPipeline(settings: cleanup).process(transcript: transcribed.transcript, app: appName)
    let cleanedAt = monotonicMs()
    record.cleanMs = Int(cleanedAt - transcribedAt)
    // Started only after delivery, so its CLI process never competes with it.
    let verifyAfterDelivery = { [self] in
      if config.pipeline?.verify ?? false {
        verify(outcome: outcome, transcript: transcribed.transcript, app: appName, takeId: takeId,
               settings: cleanup, cli: cli)
      }
    }

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
      persist(record, cli: cli)
      verifyAfterDelivery()
      DispatchQueue.main.async { self.finishProcessing(error: nil, note: "No speech detected") }
      return .handled
    case .text(let raw, let text, let mode):
      record.rawText = raw
      record.text = text
      record.mode = mode
      let steps = DeliveryPlan.steps(text: text, delivery: config.delivery, hasOriginalApp: take.originalApp != nil)
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
        persist(record, cli: cli)
        verifyAfterDelivery()
        DispatchQueue.main.async {
          self.sounds.play(.error)
          self.finishProcessing(error: error.localizedDescription)
        }
        return .handled
      }
      let deliveredAt = monotonicMs()
      record.delivered = true
      record.deliveredAtMs = Int(Date().timeIntervalSince1970 * 1000)
      record.pasteMs = Int(deliveredAt - cleanedAt)
      record.totalMs = recordMs + Int(deliveredAt - stopAt)
      logTake("delivered", endedAt: deliveredAt, transcribed: transcribed) { line in
        line.add("asr", ms: transcribedAt - startedAt)
        line.add("clean", ms: cleanedAt - transcribedAt)
        line.add("deliver", ms: deliveredAt - cleanedAt)
        line.add("waits", DeliveryPlan.waitMs(steps))
        line.add("mode", mode)
        line.add("chars", text.count)
        line.add("target", target ?? "-")
      }
      persist(record, cli: cli)
      verifyAfterDelivery()
      DispatchQueue.main.async {
        self.sounds.play(.stop)
        self.finishProcessing(error: nil)
      }
      return .handled
    }
  }

  /// History, bench and usage, one take at a time, after delivery.
  /// Returns whether the record is durably spooled (so the caller may drop
  /// any other copy, e.g. a recovered take's audio).
  @discardableResult
  private func persist(_ record: TakeRecord, cli: CLIBridge) -> Bool {
    // Spooled first, so a quit that can't wait or a crash replays it later.
    let spooled: URL?
    do {
      spooled = try pending.save(record)
    } catch {
      spooled = nil
      Log.write("persist: take \(record.takeId) not spooled: \(error.localizedDescription)")
    }
    persistQueue.async { [pending] in
      if Self.record(record, cli: cli), let spooled {
        pending.remove(spooled)
      }
    }
    return spooled != nil
  }

  /// Runs `inline record`; true once the CLI has taken the record (even if
  /// partly saved: a retry could count usage twice).
  private static func record(_ record: TakeRecord, cli: CLIBridge) -> Bool {
    do {
      let result = try cli.record(record)
      let wantsUsage = record.status == "ok" && record.delivered
      if wantsUsage && !(result.usageRecorded && result.historySaved) {
        Log.write("persist: take \(record.takeId) partly recorded (usage \(result.usageRecorded), history \(result.historySaved))")
      }
      // A recovered take exists only in history: keep it spooled until saved.
      if record.status == "recovered" && !result.historySaved {
        Log.write("persist: recovered take \(record.takeId) not in history yet (kept for the next launch)")
        return false
      }
      return true
    } catch {
      Log.write("persist: take \(record.takeId) not recorded yet (kept for the next launch): \(error.localizedDescription)")
      return false
    }
  }

  /// Replays takes a previous run delivered but could not record.
  private func replayPendingRecords(cli: CLIBridge) {
    persistQueue.async { [pending] in
      let (records, dropped) = pending.leftovers()
      for name in dropped {
        Log.write("persist: dropped stale or unreadable pending record \(name)")
      }
      for (url, record) in records where Self.record(record, cli: cli) {
        pending.remove(url)
        Log.write("persist: replayed take \(record.takeId) from a previous run")
      }
    }
  }

  /// `[app] verify_pipeline`: compare the native cleanup with the CLI's on
  /// the same raw transcript, off the delivery path.
  private func verify(outcome: CleanupOutcome, transcript: String, app: String?, takeId: String,
                      settings: CleanupSettings, cli: CLIBridge) {
    verifyQueue.async {
      do {
        let reference = try cli.cleanup(transcript: transcript, app: app)
        if reference.cleanup != settings {
          Log.write("verify: take \(takeId) skipped: cleanup settings changed since the take")
        } else if let mismatch = ShadowCompare.mismatch(native: outcome, cli: reference) {
          Log.write("verify: take \(takeId) \(mismatch) transcript=\(transcript.debugDescription)")
        } else {
          Log.write("verify: take \(takeId) matches the CLI")
        }
      } catch {
        Log.write("verify: take \(takeId) could not run the CLI cleanup: \(error.localizedDescription)")
      }
    }
  }

  /// Phase 2 path: `tmux-whisper inline process` transcribes, cleans up and
  /// records; the app delivers.
  private func processWithCLI(samples: [Float], take: Take, recordMs: Int, appName: String?, cli: CLIBridge,
                              stopAt: Double, config: AppConfig?, route: (path: String, reason: String)) {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("lowkey-\(UUID().uuidString).wav")
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
        DispatchQueue.main.async {
          if result.status == "no_speech" {
            self.finishProcessing(error: nil, note: "No speech detected")
          } else {
            self.sounds.play(.error)
            self.finishProcessing(error: result.message ?? result.status)
          }
        }
        return
      }
      // An invalid config.toml with no valid copy means default settings
      // (autosend on): paste without sending. Unknown settings count as that.
      let delivery = config.map { $0.safeDelivery(result.delivery) }
        ?? Delivery(autosend: false, sendMode: result.delivery.sendMode, pasteTarget: result.delivery.pasteTarget,
                    activateDelayMs: result.delivery.activateDelayMs, sendDelayMs: result.delivery.sendDelayMs)
      let steps = DeliveryPlan.steps(text: result.text, delivery: delivery, hasOriginalApp: take.originalApp != nil)
      let delivering = monotonicMs()
      let target = try Deliverer.perform(steps, originalApp: take.originalApp)
      logTake("delivered") { line in
        line.add("transcribe", result.timings["transcribe_ms"])
        line.add("deliver", ms: monotonicMs() - delivering)
        line.add("waits", DeliveryPlan.waitMs(steps))
        line.add("mode", result.mode)
        line.add("chars", result.text.count)
        line.add("target", target ?? "-")
      }
      DispatchQueue.main.async {
        self.sounds.play(.stop)
        self.finishProcessing(error: nil)
      }
    } catch {
      logTake("failed") { $0.add("error", Self.errorCategory(error)) }
      DispatchQueue.main.async {
        self.sounds.play(.error)
        self.finishProcessing(error: error.localizedDescription)
      }
    }
  }

  private func finishProcessing(error: String?, note: String? = nil) {
    processing = max(0, processing - 1)
    if let error {
      fail(error)
      return
    }
    if let note { Log.write("note: \(note)") }
    if take != nil {
      phase = .recording
    } else {
      phase = processing > 0 ? .processing : .ready
    }
  }

  private func fail(_ message: String) {
    Log.write("error: \(message)")
    phase = .error(message)
  }

  // MARK: - Settings

  @objc private func reloadSettings() {
    guard let cli else { return }
    work.async { [weak self] in
      do {
        let config = try cli.appConfig()
        DispatchQueue.main.async { self?.apply(config) }
      } catch {
        DispatchQueue.main.async { self?.fail("cannot read settings: \(error.localizedDescription)") }
      }
    }
  }

  private func apply(_ config: AppConfig) {
    let firstSettings = self.config == nil
    self.config = config
    sweepStaleMarkers()
    sounds.load(from: config)
    showConfigStatus(config)
    recoverLeftoverTakes(config: config)
    configureSupervision(config, trigger: firstSettings ? .launch : .settings)
    do {
      let spec = try HotkeySpec.parse(config.hotkey)
      Log.write("settings: hotkey \(spec.display), cli \(config.cliVersion), pipeline "
                + (config.nativePipelineBlocker.map { "CLI (\($0))" } ?? "native"
                   + ((config.pipeline?.verify ?? false) ? " + verify" : "")))
      if take != nil || starter.isStarting {
        // Re-registering now could drop the press that stops this take. The
        // latest settings win: a change back to the current key clears it.
        pendingHotkey = spec != hotkey.binding ? spec : nil
        if let pendingHotkey {
          Log.write("settings: hotkey change to \(pendingHotkey.display) waits for the current take to end")
        }
        return
      }
      pendingHotkey = nil
      if registerHotkey(spec) {
        if case .error = phase { phase = .ready } else { refreshStatus() }
      }
    } catch {
      pendingHotkey = nil
      hotkeyLine.title = "Hotkey: invalid (\(config.hotkey))" + (hotkey.binding.map { ", still \($0.display)" } ?? "")
      fail("hotkey \"\(config.hotkey)\": \(error)")
    }
  }

  /// Binds the hotkey; if the new one can't be registered, the old binding
  /// stays in effect. Returns whether `spec` is now bound.
  @discardableResult
  private func registerHotkey(_ spec: HotkeySpec) -> Bool {
    do {
      try hotkey.register(spec)
      hotkeyLine.title = "Hotkey: \(spec.display)"
      return true
    } catch {
      let kept = hotkey.binding.map { "; keeping \($0.display)" } ?? ""
      hotkeyLine.title = "Hotkey: \(hotkey.binding?.display ?? "none") (\(spec.display) unavailable)"
      fail("\(error.localizedDescription)\(kept)")
      return false
    }
  }

  private func applyPendingHotkey() {
    guard let spec = pendingHotkey, take == nil, !starter.isStarting else { return }
    pendingHotkey = nil
    if registerHotkey(spec) { Log.write("settings: hotkey changed to \(spec.display)") }
  }

  // MARK: - Daemon supervision

  /// Points the supervisor at the configured daemon and model (or turns it
  /// off), checking right away when that target changed.
  private func configureSupervision(_ config: AppConfig, trigger: DaemonSupervisor.Trigger) {
    let target = DaemonSupervisor.Target(config: config)
    let note = config.supervisionBlocker ?? ""
    if note != supervisionNote {
      Log.write("supervisor: " + (note.isEmpty ? "keeping the daemon warm" : "off (\(note))"))
      supervisionNote = note
    }
    guard target != supervisedTarget else { return }
    supervisedTarget = target
    supervisor?.configure(target)
    if target == nil {
      daemonLine.isHidden = true
    } else {
      supervisor?.trigger(trigger)
    }
  }

  private func showDaemonState(_ state: DaemonSupervisor.State) {
    switch state {
    case .unknown:
      daemonLine.isHidden = true
      return
    case .ready:
      daemonLine.title = "Parakeet: ready"
    case .warming(let reason):
      daemonLine.title = "Parakeet: warming up (\(reason))"
    case .unavailable(let reason):
      daemonLine.title = "Parakeet: unavailable (\(reason))"
    }
    daemonLine.isHidden = false
  }

  // MARK: - Timed-out takes

  /// A retried take's text, waiting for the user to paste it.
  private struct RetriedText {
    let entry: TimedOutTakes.Entry
    let text: String
    /// The native path's record, persisted once the text is pasted (the CLI
    /// path's `inline process` has already recorded the take).
    let record: TakeRecord?
  }
  private var retried: RetriedText?
  /// A paste of the retried text is under way.
  private var pastingRetry = false
  /// Retried pastes run here, not behind other takes on `work`: they must
  /// happen while the app the user chose is still in front.
  private let pasteQueue = DispatchQueue(label: "lowkey.paste", qos: .userInitiated)

  func menuWillOpen(_ menu: NSMenu) {
    refreshTimedOutItems()
    refreshLoginItem()
  }

  // MARK: - Start at login

  private static func loginStatusText(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: return "on"
    case .requiresApproval: return "waiting for approval in System Settings"
    case .notRegistered: return "off"
    case .notFound: return "off (not found)"
    @unknown default: return "unknown (\(status.rawValue))"
    }
  }

  /// Opt-in, and macOS keeps the setting (System Settings → General →
  /// Login Items), so there's nothing in config.toml. Registered by bundle,
  /// so a rebuild in place keeps it; moving the app needs a re-toggle.
  private func refreshLoginItem() {
    let status = SMAppService.mainApp.status
    loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
    loginItem.title = status == .requiresApproval ? "Start at Login (approve in System Settings)" : "Start at Login"
  }

  @objc private func toggleStartAtLogin() {
    let service = SMAppService.mainApp
    do {
      switch service.status {
      case .enabled:
        try service.unregister()
      case .requiresApproval:
        // Registered, but macOS wants the user's say-so: show where.
        SMAppService.openSystemSettingsLoginItems()
      default:
        try service.register()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
      }
      Log.write("login: start at login \(Self.loginStatusText(service.status))")
    } catch {
      Log.write("login: could not change start at login: \(error.localizedDescription)")
      fail("could not change Start at Login: \(error.localizedDescription)")
    }
    refreshLoginItem()
  }

  /// Shows Retry / Paste / Discard while a timed-out take is kept (expired
  /// ones are deleted here).
  private func refreshTimedOutItems() {
    let entries = timedOut.all()
    if let pending = retried, !entries.contains(pending.entry) {
      retried = nil // expired or removed
    }
    retryItem.isHidden = entries.isEmpty || retrying || retried != nil
    pasteRetriedItem.isHidden = retried == nil || retrying || pastingRetry
    discardTimedOutItem.isHidden = entries.isEmpty || retrying || pastingRetry
    if let retried {
      pasteRetriedItem.title = "Paste retried dictation (\(retried.text.count) chars, doesn't send)"
    }
    if let newest = entries.last {
      retryItem.title = "Retry timed-out recording (\(newest.info.recordMs / 1000)s"
        + (entries.count > 1 ? ", \(entries.count) kept" : "") + ")"
    }
    discardTimedOutItem.title = entries.count > 1 ? "Discard \(entries.count) timed-out recordings" : "Discard timed-out recording"
  }

  @objc private func discardTimedOut() {
    guard !pastingRetry else { return }
    let entries = timedOut.all()
    entries.forEach(timedOut.remove)
    retried = nil
    Log.write("retry: discarded \(entries.count) timed-out recording(s)")
    refreshTimedOutItems()
  }

  /// Transcribes the newest timed-out take again (natively when the daemon
  /// holds the model now, else through `inline process`). Nothing is pasted
  /// until the user chooses "Paste retried dictation" in the app they want
  /// it in: by now, focus may be anywhere.
  @objc private func retryTimedOut() {
    guard let cli, let entry = timedOut.all().last, !retrying, retried == nil else { return }
    retrying = true
    refreshTimedOutItems()
    processing += 1
    phase = .processing
    let marker = TakeMarker.create(directory: markerDirectory, takeId: entry.info.takeId + "-retry", phase: .processing)
    work.async { [weak self] in
      defer { marker?.remove() }
      guard let self else { return }
      let outcome = self.retranscribe(entry, cli: cli)
      DispatchQueue.main.async {
        self.retrying = false
        switch outcome {
        case .ready(let result):
          self.retried = result
          Log.write("retry: transcribed a timed-out recording (\(result.text.count) chars); waiting for Paste")
          self.sounds.play(.stop)
          self.finishProcessing(error: nil, note: "Retried dictation ready: choose Paste in the menu")
        case .noSpeech:
          self.finishProcessing(error: nil, note: "No speech detected")
        case .failed(let message):
          self.sounds.play(.error)
          self.finishProcessing(error: message)
        }
        self.refreshTimedOutItems()
      }
    }
  }

  /// Pastes the retried text into the app in front (never sends). The
  /// recording is dropped only once the paste went through.
  @objc private func pasteRetried() {
    guard let pending = retried, let cli, !pastingRetry else { return }
    pastingRetry = true
    refreshTimedOutItems()
    // Lowkey never takes focus, so this is the app the user chose Paste in.
    let chosen = NSWorkspace.shared.frontmostApplication
    let delivery = Delivery(autosend: false, sendMode: "enter", pasteTarget: "current", activateDelayMs: 0, sendDelayMs: 0)
    pasteQueue.async { [weak self] in
      defer {
        DispatchQueue.main.async {
          self?.pastingRetry = false
          self?.refreshTimedOutItems()
        }
      }
      // Let the menu close so the paste reaches the app underneath.
      usleep(200_000)
      let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
      guard front?.processIdentifier == chosen?.processIdentifier else {
        DispatchQueue.main.async {
          self?.fail("didn't paste: \(front?.localizedName ?? "another app") came to the front; choose Paste again")
        }
        return
      }
      do {
        let target = try Deliverer.perform(DeliveryPlan.steps(text: pending.text, delivery: delivery, hasOriginalApp: false),
                                           originalApp: nil)
        if var record = pending.record {
          record.delivered = true
          record.deliveredAtMs = Int(Date().timeIntervalSince1970 * 1000)
          self?.persist(record, cli: cli)
        }
        self?.timedOut.remove(pending.entry)
        Log.write("retry: pasted a retried dictation (\(pending.text.count) chars, target=\(target ?? "-"))")
        DispatchQueue.main.async {
          self?.retried = nil
          self?.refreshTimedOutItems()
        }
      } catch {
        DispatchQueue.main.async {
          self?.sounds.play(.error)
          self?.fail("paste failed (the text is on the clipboard; the recording is kept): \(error.localizedDescription)")
        }
      }
    }
  }

  private enum RetryOutcome {
    case ready(RetriedText)
    case noSpeech
    case failed(String)
  }

  private func retranscribe(_ entry: TimedOutTakes.Entry, cli: CLIBridge) -> RetryOutcome {
    let info = entry.info
    let startedAt = monotonicMs()
    let config: AppConfig
    do {
      config = try cli.appConfig()
    } catch {
      return .failed("retry: cannot read settings: \(error.localizedDescription)")
    }
    // Natively only if the daemon is warm now; otherwise the CLI starts it.
    guard config.nativePipelineBlocker == nil, let transcription = config.transcription, let cleanup = config.cleanup,
          let modelPath = transcription.modelPath,
          DaemonClient(socketPath: transcription.socketPath).status(timeout: 1)?
            .holds(path: modelPath, version: transcription.modelVersion ?? "v3") == true else {
      return retranscribeWithCLI(entry, cli: cli)
    }
    let samples: [Float]
    do {
      samples = try RecoveredTakes.samples(at: entry.wav)
    } catch {
      return .failed("retry: the kept recording is unreadable")
    }
    let client = DaemonClient(socketPath: transcription.socketPath)
    let timeout = min(transcription.maxTimeout, 30 + 2 * Double(samples.count) / Double(AudioPrep.sampleRate))
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
      return retranscribeWithCLI(entry, cli: cli)
    case .noSpeech:
      record.status = "no_speech"
      persist(record, cli: cli)
      timedOut.remove(entry)
      return .noSpeech
    case .text(let raw, let text, let mode):
      record.rawText = raw
      record.text = text
      record.mode = mode
      return .ready(RetriedText(entry: entry, text: text, record: record))
    }
  }

  /// `inline process` on the kept WAV (it records history and usage itself).
  private func retranscribeWithCLI(_ entry: TimedOutTakes.Entry, cli: CLIBridge) -> RetryOutcome {
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
      return .ready(RetriedText(entry: entry, text: result.text, record: nil))
    } catch {
      return .failed("retry failed (recording kept): \(error.localizedDescription)")
    }
  }

  /// Warns in the menu (and log) while config.toml doesn't parse.
  private func showConfigStatus(_ config: AppConfig) {
    guard let status = config.config, let error = status.error else {
      configLine.isHidden = true
      return
    }
    let using = status.source == "last_good"
      ? "using the last valid settings"
      : "using defaults, paste without sending"
    configLine.title = "⚠︎ config.toml invalid: \(using)"
    configLine.isHidden = false
    Log.write("settings: config.toml invalid (\(error)); \(using)")
  }

  // MARK: - Menu

  private func buildMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    statusLine.isEnabled = false
    hotkeyLine.isEnabled = false
    configLine.isEnabled = false
    configLine.isHidden = true
    recoveredLine.isEnabled = false
    recoveredLine.isHidden = true
    cancelItem.target = self
    menu.addItem(statusLine)
    menu.addItem(hotkeyLine)
    menu.addItem(configLine)
    menu.addItem(recoveredLine)
    daemonLine.isEnabled = false
    daemonLine.isHidden = true
    menu.addItem(daemonLine)
    retryItem.target = self
    retryItem.isHidden = true
    menu.addItem(retryItem)
    pasteRetriedItem.target = self
    pasteRetriedItem.isHidden = true
    menu.addItem(pasteRetriedItem)
    discardTimedOutItem.target = self
    discardTimedOutItem.isHidden = true
    menu.addItem(discardTimedOutItem)
    discardItem.target = self
    discardItem.isHidden = true
    menu.addItem(discardItem)
    menu.addItem(.separator())
    menu.addItem(cancelItem)
    let reload = NSMenuItem(title: "Reload Settings", action: #selector(reloadSettings), keyEquivalent: "r")
    reload.target = self
    menu.addItem(reload)
    let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "l")
    log.target = self
    menu.addItem(log)
    loginItem.target = self
    menu.addItem(loginItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Lowkey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    menu.delegate = self
    statusItem.menu = menu
    refreshStatus()
  }

  @objc private func openLog() {
    NSWorkspace.shared.open(Log.fileURL)
  }

  private func refreshStatus() {
    let symbol: String
    switch phase {
    case .ready:
      symbol = "mic"
      statusLine.title = "Ready"
    case .recording:
      symbol = "mic.fill"
      statusLine.title = "Recording…"
    case .processing:
      symbol = "waveform"
      statusLine.title = processing > 1 ? "Processing (\(processing))…" : "Processing…"
    case .error(let message):
      symbol = "exclamationmark.triangle"
      statusLine.title = "Error: \(message)"
    }
    cancelItem.isHidden = take == nil
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lowkey")
    image?.isTemplate = true
    statusItem?.button?.image = image
  }
}
