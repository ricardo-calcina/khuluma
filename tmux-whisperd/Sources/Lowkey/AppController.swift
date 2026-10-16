import AppKit
import Foundation
import LowkeyCore

/// Menu-bar app: hotkey → chime + capture → transcription and cleanup →
/// paste/send. Owns the take's lifecycle and the app's state; the work of a
/// take is in `TakePipeline`, persistence in `TakePersister`, the menu in
/// `StatusMenu`.
final class AppController: NSObject, NSApplicationDelegate {
  /// If no audio has arrived this long after the engine started, chime
  /// anyway (and log it) rather than leave the press unanswered.
  private static let chimeFallback: TimeInterval = 0.75

  private let menu = StatusMenu()
  private let recorder = AudioRecorder()
  private let sounds = SoundPlayer()
  private lazy var hotkey = HotkeyMonitor { [weak self] in self?.toggle() }
  /// Ctrl+Esc cancels a recording. Bound only while
  /// recording, so the combination stays free for other apps otherwise.
  private lazy var cancelHotkey = HotkeyMonitor(signature: 0x4C4B434E /* 'LKCN' */) { [weak self] in
    self?.cancelRecording()
  }
  private static let cancelKey = try! HotkeySpec.parse("ctrl+escape")
  /// One start at a time; a failed start never leaves its marker behind.
  private let starter = TakeStarter()
  private var cli: CLIBridge?
  /// Set with `cli`: transcription, delivery and persistence of takes.
  private var pipeline: TakePipeline?
  private var config: AppConfig?
  private var take: Take?
  /// Set once Quit has begun: the hotkey no longer starts new takes.
  private var quitting = false
  private var status = ActivityStatus() { didSet { refreshStatus() } }
  private let work = DispatchQueue(label: "lowkey.work", qos: .userInitiated)
  private let recovered = RecoveredTakes.standard
  private var recoveryRunning = false
  private let settingsQueue = DispatchQueue(label: "lowkey.settings", qos: .userInitiated, attributes: .concurrent)
  /// Where take markers go: the CLI's processing dir.
  private var markerDirectory: String { config?.transcription.processingDir ?? TakeMarker.defaultDirectory }
  /// Marker dirs already swept for a previous run's leftovers.
  private var sweptMarkerDirectories: Set<String> = []
  /// Keeps the daemon warm; nil until the CLI is found.
  private var supervisor: DaemonSupervisor?
  /// Why supervision is off, as last logged ("" = on).
  private var supervisionNote: String?
  private var supervisedTarget: DaemonSupervisor.Target?
  /// Set while the installed CLI speaks a different app contract: takes are
  /// refused until settings from a matching CLI arrive.
  private var contractMismatch: AppContract.Mismatch?
  /// A hotkey change read while a take was recording, applied when it ends.
  private var pendingHotkey: HotkeySpec?
  /// Takes whose transcription timed out, for Retry/Discard.
  private let timedOut = TimedOutTakes.standard
  /// The last active app other than Lowkey: a take started with Lowkey in
  /// front is meant for it.
  private var lastExternalApp: NSRunningApplication?
  /// Every take stopped for Quit whose audio couldn't be written yet.
  private var unsaved: [UnsavedTake] = []
  /// Stopped takes until they end (queued or being transcribed): Quit saves
  /// their audio, in case the drain runs out before they finish.
  private let inFlight = InFlightTakes(store: .standard)
  /// Made on first open, then reused.
  private var statsWindow: StatsWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    connectMenu()
    menu.install()
    sweepStaleMarkers()
    Log.write("launch: Lowkey \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
              + ", start at login \(LoginItem.text(LoginItem.status))")

    recorder.prepare()
    recorder.onConfigurationChange = { [weak self] in self?.handleDeviceChange() }
    AudioRecorder.requestPermission { granted in
      if !granted { Log.write("permission: microphone denied") }
    }
    if !Deliverer.isTrusted(prompt: true) {
      Log.write("permission: accessibility not granted yet (prompted)")
    }

    guard let cli = CLIBridge.locate() else {
      status.failed("tmux-whisper CLI not found")
      return
    }
    self.cli = cli
    let pipeline = TakePipeline(cli: cli, persister: TakePersister(cli: cli)) { [weak self] in
      self?.supervisor?.trigger(.unreachable)
    }
    self.pipeline = pipeline
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
    trackExternalApps()
    reloadSettings()
    pipeline.persister.replayLeftovers()
    refreshTimedOutItems()
    // `-LowkeyOpenStats YES`: open Stats at launch (for checking the window).
    if UserDefaults.standard.bool(forKey: "LowkeyOpenStats") {
      showStats()
    }
  }

  private func connectMenu() {
    menu.onCancelRecording = { [weak self] in self?.cancelRecording() }
    menu.onRetryTimedOut = { [weak self] in self?.retryTimedOut() }
    menu.onPasteRetried = { [weak self] in self?.pasteRetried() }
    menu.onDiscardTimedOut = { [weak self] in self?.discardTimedOut() }
    menu.onDiscardUnsaved = { [weak self] in self?.discardUnsavedAndQuit() }
    menu.onShowRecovered = { [weak self] in
      guard let self else { return }
      NSWorkspace.shared.activateFileViewerSelecting(self.recovered.all())
    }
    menu.onShowStats = { [weak self] in self?.showStats() }
    menu.onReloadSettings = { [weak self] in self?.reloadSettings() }
    menu.onToggleLogin = { [weak self] in self?.toggleStartAtLogin() }
    menu.onWillOpen = { [weak self] in
      self?.refreshTimedOutItems()
      self?.menu.showLogin(LoginItem.status)
    }
  }

  // MARK: - Quit

  /// Quit never discards a dictation. A take still recording is saved to
  /// disk at once, then transcribed into history and onto the clipboard
  /// (never pasted or sent: the app in front at quit time, e.g. the terminal
  /// running a rebuild, is not where it was meant to go). Takes already
  /// stopped (queued or being transcribed) are saved to disk too, then
  /// finish as usual; each one that does drops its saved copy. They and
  /// persistence get up to 30 s; whatever doesn't finish is recovered at the
  /// next launch (saved audio, spooled records).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateLater }
    if take != nil || !unsaved.isEmpty {
      guard saveRecordingForQuit() else {
        // Couldn't write the audio: stay open rather than lose a take. Only
        // the explicit "Discard … and quit" menu item gives it up.
        menu.showDiscardUnsaved("Discard \(unsaved.count) unsaved recording\(unsaved.count == 1 ? "" : "s") and quit")
        fail("couldn't save \(unsaved.count) recording\(unsaved.count == 1 ? "" : "s") for quitting; Quit retries")
        return .terminateCancel
      }
    }
    saveInFlightForQuit()
    return terminateAfterDraining()
  }

  /// Writes the audio of takes still queued or being transcribed. One that
  /// can't be written isn't lost yet: it may still finish in the drain, and
  /// the drain's timeout tries again before giving up.
  private func saveInFlightForQuit() {
    guard inFlight.count > 0 else { return }
    let (saved, failed) = inFlight.saveAll()
    Log.write("quit: saved \(saved) take(s) still being transcribed to recovered/ (deleted as each finishes)"
              + (failed > 0 ? "; \(failed) couldn't be written yet" : ""))
  }

  private func discardUnsavedAndQuit() {
    Log.write("quit: discarding \(unsaved.count) unsaved recording(s) at the user's request")
    unsaved.forEach { $0.marker?.remove() }
    unsaved.removeAll()
    menu.showDiscardUnsaved(nil)
    NSApp.terminate(nil)
  }

  private func terminateAfterDraining() -> NSApplication.TerminateReply {
    quitting = true
    let replied = DispatchSemaphore(value: 1)
    let reply = {
      guard replied.wait(timeout: .now()) == .success else { return }
      DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    let persistQueue = pipeline?.persister.queue
    work.async {
      guard let persistQueue else { return reply() }
      persistQueue.async { reply() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, inFlight] in
      guard replied.wait(timeout: .now()) == .success else { return }
      // Last chance for takes whose audio couldn't be written at Quit.
      let failed = inFlight.saveAll().failed
      guard failed == 0 else {
        // Stay open rather than lose them; they finish (or Quit saves them) later.
        self?.quitting = false
        NSApp.reply(toApplicationShouldTerminate: false)
        self?.fail("couldn't save \(failed) recording\(failed == 1 ? "" : "s") still being transcribed; quit again once "
                   + (failed == 1 ? "it finishes" : "they finish"))
        return
      }
      Log.write("quit: pending work did not finish within 30s; quitting (saved audio and spooled takes are recovered at next launch)")
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

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
    // With a mismatched CLI the audio is only saved, for the next launch.
    let config = contractMismatch == nil ? self.config : nil
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
    if unsaved.isEmpty { menu.showDiscardUnsaved(nil) }
    return unsaved.isEmpty
  }

  // MARK: - Saved takes

  /// Runs on `work`. See `TakePipeline.recover`.
  private func recover(url: URL, samples: [Float], takeId: String, startedEpochMs: Int?, startupMs: Int,
                       app: String?, config: AppConfig?, copy: Bool) {
    guard let pipeline else {
      Log.write("recover: \(url.lastPathComponent) kept for later (native pipeline unavailable)")
      return
    }
    pipeline.recover(url: url, samples: samples, takeId: takeId, startedEpochMs: startedEpochMs,
                     startupMs: startupMs, app: app, config: config, copy: copy, store: recovered)
  }

  /// Takes saved at a previous quit that didn't finish: transcribe them into
  /// history (no clipboard: it may hold something newer) and say so.
  private func recoverLeftoverTakes(config: AppConfig) {
    // While quitting, saved takes are already queued or still in flight.
    guard !quitting else { return }
    let leftovers = leftoverTakes()
    guard !leftovers.isEmpty, !recoveryRunning else { return }
    guard config.nativePipelineBlocker == nil else {
      // Can't transcribe natively with these settings: say so, and retry
      // whenever usable settings arrive.
      menu.showRecovered("Saved dictations waiting (\(leftovers.count)): Show in Finder", action: true)
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
      let remaining = self.leftoverTakes().count
      let done = leftovers.count - remaining
      DispatchQueue.main.async {
        self.recoveryRunning = false
        if remaining > 0 {
          self.menu.showRecovered("Saved dictations waiting (\(remaining)): Show in Finder", action: true)
        } else if done > 0 {
          self.menu.showRecovered(
            "Recovered \(done) dictation\(done == 1 ? "" : "s") from the last quit (tmux-whisper history)", action: false)
        }
      }
    }
  }

  /// Saved takes waiting for transcription: not the copies of takes still
  /// in flight (after a Quit that couldn't finish), which finish on their own.
  private func leftoverTakes() -> [URL] {
    let inFlightCopies = inFlight.savedFiles()
    return recovered.all().filter { !inFlightCopies.contains($0) }
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
      if let contractMismatch {
        // Checked again now, so the press after a reinstall works.
        sounds.play(.error)
        fail(contractMismatch.localizedDescription)
        reloadSettings()
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
    let frontmost = NSWorkspace.shared.frontmostApplication
    let original = DeliveryTarget.original(
      frontmost: frontmost,
      lastExternal: lastExternalApp.flatMap { $0.isTerminated ? nil : $0 },
      isSelf: { $0.processIdentifier == getpid() })
    let retargeted = frontmost?.processIdentifier == getpid() && original != nil
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
      let refuse: (AppContract.Mismatch) -> Void = { [weak self] mismatch in
        DispatchQueue.main.async { self?.refuseTakes(mismatch) }
      }
      take = Take(
        hotkeyAt: hotkeyAt,
        startedAt: startedAt,
        startedEpochMs: Int(Date().timeIntervalSince1970 * 1000),
        startupMs: Int((startedAt - hotkeyAt).rounded()),
        originalApp: original,
        retargeted: retargeted,
        settings: cli.map { SettingsFetch(cli: $0, queue: settingsQueue, onMismatch: refuse) },
        marker: marker,
        chime: chime
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.chimeFallback) {
        playChime("with no audio yet after \(Int(Self.chimeFallback * 1000))ms")
      }
      status.recordingStarted()
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
    status.processingStarted()
    process(samples: samples, take: take, recordMs: recordMs, stopAt: stopAt)
  }

  private func cancelRecording() {
    guard let take else { return }
    take.chime.cancel()
    cancelHotkey.unregister()
    _ = recorder.stop()
    take.marker?.remove()
    self.take = nil
    sounds.play(.cancel)
    status.recordingCancelled()
    Log.write("cancel: recording discarded")
    applyPendingHotkey()
  }

  private func handleDeviceChange() {
    guard take != nil else { return }
    // The engine stops on a device switch; keep what was captured so far.
    Log.write("audio: device changed mid-recording; stopping the take")
    stopRecording()
  }

  // MARK: - Processing

  private func process(samples: [Float], take: Take, recordMs: Int, stopAt: Double) {
    guard let pipeline else {
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
    // In memory only until the take ends: Quit saves it from here.
    let takeId = inFlight.add(samples: samples)
    work.async { [weak self, inFlight] in
      // Every path below is synchronous on this queue: the take is over when
      // it returns (its record spooled, its audio kept elsewhere, or failed).
      defer {
        take.marker?.remove()
        inFlight.finish(takeId)
      }
      guard let self else { return }
      take.marker?.update(.processing)
      // Settings fetched during the recording; usually ready long before
      // stop. The wait outlasts the fetch's own timeout, so no take reaches
      // a CLI whose contract is still unknown. Without settings (the CLI
      // failed), the CLI path reads its own.
      var fresh: AppConfig?
      var problem: String?
      switch take.settings?.wait(timeout: 20) ?? .unavailable("no settings fetch") {
      case .config(let config): fresh = config
      case .unavailable(let reason): problem = reason
      case .mismatch(let mismatch):
        self.keepForMatchingCLI(samples: samples, take: take, takeId: takeId, recordMs: recordMs, mismatch: mismatch)
        return
      }
      // A mismatch found since this take's fetch (a reload, while recording
      // or queued) is newer than its settings: read it now, on main.
      if let mismatch = DispatchQueue.main.sync(execute: { self.contractMismatch }) {
        self.keepForMatchingCLI(samples: samples, take: take, takeId: takeId, recordMs: recordMs, mismatch: mismatch)
        return
      }
      if let fresh, fresh != cachedConfig {
        DispatchQueue.main.async { self.adopt(fresh) }
      }
      let config = fresh ?? cachedConfig
      // Match the CLI: "restore" uses the app from recording start; "current"
      // uses whatever is frontmost when processing begins (for mode detection).
      // A retargeted take is delivered to its original app, so it's that one.
      let appName = DeliveryTarget.modeApp(pasteTarget: config?.inline.pasteTarget, retargeted: take.retargeted,
                                           original: take.originalApp?.localizedName, frontmostAtStop: frontmostAtStop)
      // How the take reaches the CLI path, for the take log.
      let route: (path: String, reason: String)
      if let fresh {
        if let blocker = fresh.nativePipelineBlocker {
          route = ("cli", blocker)
        } else {
          switch pipeline.processNatively(samples: samples, take: take, takeId: takeId, recordMs: recordMs,
                                          appName: appName, config: fresh, stopAt: stopAt) {
          case .handled(let result):
            DispatchQueue.main.async { self.finish(result) }
            return
          case .fallback(let reason): route = ("fallback", reason)
          }
        }
      } else {
        Log.write("pipeline: CLI path (\(problem ?? "settings unavailable"))")
        route = ("cli", problem ?? "settings unavailable")
      }
      take.marker?.update(.cli)
      let result = pipeline.processWithCLI(samples: samples, take: take, recordMs: recordMs, appName: appName,
                                           stopAt: stopAt, config: config, route: route)
      DispatchQueue.main.async { self.finish(result) }
    }
  }

  /// Shows how a take ended.
  private func finish(_ result: TakeResult) {
    switch result {
    case .delivered:
      sounds.play(.stop)
      finishProcessing(error: nil)
    case .noSpeech:
      finishProcessing(error: nil, note: "No speech detected")
    case .failed(let message):
      sounds.play(.error)
      finishProcessing(error: message)
    case .timedOut(let message):
      sounds.play(.error)
      refreshTimedOutItems()
      finishProcessing(error: message)
    }
  }

  /// The CLI changed under a take to one Lowkey can't use: nothing is
  /// transcribed with it. The audio is saved like a quit's, and transcribed
  /// into history once a matching CLI's settings arrive. If it can't be
  /// written it stays in memory, and Quit retries like any unsaved take.
  /// Runs on `work`.
  private func keepForMatchingCLI(samples: [Float], take: Take, takeId: String, recordMs: Int,
                                  mismatch: AppContract.Mismatch) {
    let kept: Bool
    do {
      // Reuses the copy Quit saved, if it got there first.
      let url = try inFlight.keep(takeId)
      Log.write("pipeline: CLI contract mismatch; saved the recording to \(url.lastPathComponent)")
      kept = true
    } catch {
      Log.write("pipeline: CLI contract mismatch; could not save the recording: \(error.localizedDescription)")
      kept = false
    }
    var line = TakeLog()
    line.add("path", "none")
    line.add("outcome", "failed")
    line.add("record", recordMs)
    line.add("error", "cli_mismatch")
    line.add("kept", kept ? 1 : 0)
    Log.write(line.line)
    DispatchQueue.main.async {
      self.refuseTakes(mismatch)
      if kept {
        self.menu.showRecovered("Saved dictations waiting (\(self.leftoverTakes().count)): Show in Finder", action: true)
      } else {
        self.unsaved.append(UnsavedTake(samples: samples, takeId: takeId, startedEpochMs: take.startedEpochMs,
                                        startupMs: take.startupMs, app: take.originalApp?.localizedName, marker: nil))
      }
      self.sounds.play(.error)
      self.finishProcessing(error: mismatch.localizedDescription + (kept ? " (recording saved)" : " (recording kept until Quit)"))
      // The mismatch may be older than a reinstall since: check again.
      self.reloadSettings()
    }
  }

  /// Stops using a CLI that speaks another app contract: no takes, no
  /// daemon supervision, until `apply` gets settings from a matching one.
  private func refuseTakes(_ mismatch: AppContract.Mismatch) {
    if contractMismatch != mismatch {
      Log.write("settings: \(mismatch.localizedDescription)")
    }
    contractMismatch = mismatch
    supervisedTarget = nil
    supervisor?.configure(nil)
    menu.showDaemon(nil)
  }

  private func sweepStaleMarkers() {
    let directory = markerDirectory
    guard sweptMarkerDirectories.insert(directory).inserted else { return }
    for name in TakeMarker.removeStale(directory: directory) {
      Log.write("markers: removed \(name), left by a previous run")
    }
  }

  private func finishProcessing(error: String?, note: String? = nil) {
    if let error {
      Log.write("error: \(error)")
    } else if let note {
      Log.write("note: \(note)")
    }
    status.processingFinished(error: error, recording: take != nil)
  }

  private func fail(_ message: String) {
    Log.write("error: \(message)")
    status.failed(message)
  }

  private func refreshStatus() {
    menu.show(status, recording: take != nil)
  }

  // MARK: - Settings

  private func reloadSettings() {
    guard let cli else { return }
    work.async { [weak self] in
      do {
        let config = try cli.appConfig()
        DispatchQueue.main.async { self?.apply(config) }
      } catch let mismatch as AppContract.Mismatch {
        DispatchQueue.main.async {
          self?.refuseTakes(mismatch)
          self?.fail(mismatch.localizedDescription)
        }
      } catch {
        DispatchQueue.main.async { self?.fail("cannot read settings: \(error.localizedDescription)") }
      }
    }
  }

  private func apply(_ config: AppConfig) {
    let firstSettings = self.config == nil
    self.config = config
    contractMismatch = nil
    sweepStaleMarkers()
    sounds.load(from: config)
    showConfigStatus(config)
    recoverLeftoverTakes(config: config)
    configureSupervision(config, trigger: firstSettings ? .launch : .settings)
    do {
      let spec = try HotkeySpec.parse(config.hotkey)
      Log.write("settings: hotkey \(spec.display), cli \(config.cliVersion) (contract \(config.appContract)), pipeline "
                + (config.nativePipelineBlocker.map { "CLI (\($0))" } ?? "native"))
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
        status.clearError()
      }
    } catch {
      pendingHotkey = nil
      menu.showHotkey("Hotkey: invalid (\(config.hotkey))" + (hotkey.binding.map { ", still \($0.display)" } ?? ""))
      fail("hotkey \"\(config.hotkey)\": \(error)")
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

  /// Warns in the menu (and log) while config.toml doesn't parse.
  private func showConfigStatus(_ config: AppConfig) {
    let status = config.config
    guard let error = status.error else {
      menu.showConfigWarning(nil)
      return
    }
    let using = status.source == "last_good"
      ? "using the last valid settings"
      : "using defaults, paste without sending"
    menu.showConfigWarning("⚠︎ config.toml invalid: \(using)")
    Log.write("settings: config.toml invalid (\(error)); \(using)")
  }

  /// Binds the hotkey; if the new one can't be registered, the old binding
  /// stays in effect. Returns whether `spec` is now bound.
  @discardableResult
  private func registerHotkey(_ spec: HotkeySpec) -> Bool {
    do {
      try hotkey.register(spec)
      menu.showHotkey("Hotkey: \(spec.display)")
      return true
    } catch {
      let kept = hotkey.binding.map { "; keeping \($0.display)" } ?? ""
      menu.showHotkey("Hotkey: \(hotkey.binding?.display ?? "none") (\(spec.display) unavailable)")
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
      menu.showDaemon(nil)
    } else {
      supervisor?.trigger(trigger)
    }
  }

  private func showDaemonState(_ state: DaemonSupervisor.State) {
    switch state {
    case .unknown:
      menu.showDaemon(nil)
    case .ready:
      menu.showDaemon("Parakeet: ready")
      // Saved takes that failed while the daemon was down or loading.
      if let config, contractMismatch == nil { recoverLeftoverTakes(config: config) }
    case .warming(let reason):
      menu.showDaemon("Parakeet: warming up (\(reason))")
    case .unavailable(let reason):
      menu.showDaemon("Parakeet: unavailable (\(reason))")
    }
  }

  // MARK: - Timed-out takes

  private var retrying = false
  private var retried: RetriedText?
  /// A paste of the retried text is under way.
  private var pastingRetry = false
  /// Retried pastes run here, not behind other takes on `work`: they must
  /// happen while the app the user chose is still in front.
  private let pasteQueue = DispatchQueue(label: "lowkey.paste", qos: .userInitiated)

  /// Shows Retry / Paste / Discard while a timed-out take is kept (expired
  /// ones are deleted here).
  private func refreshTimedOutItems() {
    let entries = timedOut.all()
    if let pending = retried, !entries.contains(pending.entry) {
      retried = nil // expired or removed
    }
    let retry = entries.last.flatMap { newest -> String? in
      guard !retrying, retried == nil else { return nil }
      return "Retry timed-out recording (\(newest.info.recordMs / 1000)s"
        + (entries.count > 1 ? ", \(entries.count) kept" : "") + ")"
    }
    let paste = retried.flatMap { pending -> String? in
      guard !retrying, !pastingRetry else { return nil }
      return "Paste retried dictation (\(pending.text.count) chars, doesn't send)"
    }
    let discard = entries.isEmpty || retrying || pastingRetry ? nil
      : (entries.count > 1 ? "Discard \(entries.count) timed-out recordings" : "Discard timed-out recording")
    menu.showTimedOut(retry: retry, paste: paste, discard: discard)
  }

  private func discardTimedOut() {
    guard !pastingRetry else { return }
    let entries = timedOut.all()
    entries.forEach(timedOut.remove)
    retried = nil
    Log.write("retry: discarded \(entries.count) timed-out recording(s)")
    refreshTimedOutItems()
  }

  /// Transcribes the newest timed-out take again. Nothing is pasted until
  /// the user chooses "Paste retried dictation" in the app they want it in:
  /// by now, focus may be anywhere.
  private func retryTimedOut() {
    guard let pipeline, let entry = timedOut.all().last, !retrying, retried == nil else { return }
    retrying = true
    refreshTimedOutItems()
    status.processingStarted()
    let marker = TakeMarker.create(directory: markerDirectory, takeId: entry.info.takeId + "-retry", phase: .processing)
    work.async { [weak self] in
      defer { marker?.remove() }
      guard let self else { return }
      let outcome = pipeline.retranscribe(entry)
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
  private func pasteRetried() {
    guard let pending = retried, let pipeline, !pastingRetry else { return }
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
          let deliveredDate = Date()
          record.delivered = true
          record.deliveredAtMs = Int(deliveredDate.timeIntervalSince1970 * 1000)
          record.deliveredLocalDate = LocalDate.string(for: deliveredDate)
          pipeline.persister.persist(record)
        }
        pipeline.timedOut.remove(pending.entry)
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

  // MARK: - Other

  private func toggleStartAtLogin() {
    do {
      try LoginItem.toggle()
      Log.write("login: start at login \(LoginItem.text(LoginItem.status))")
    } catch {
      Log.write("login: could not change start at login: \(error.localizedDescription)")
      fail("could not change Start at Login: \(error.localizedDescription)")
    }
    menu.showLogin(LoginItem.status)
  }

  /// Remembers the last active app other than Lowkey (see `startRecording`).
  private func trackExternalApps() {
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
      lastExternalApp = front
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.processIdentifier != getpid() else { return }
      self?.lastExternalApp = app
    }
  }

  private func showStats() {
    MainActor.assumeIsolated {
      let window = statsWindow ?? StatsWindowController(
        model: StatsModel { [weak self] in StatsModel.Source(cli: self?.cli, config: self?.config) })
      statsWindow = window
      window.show()
    }
  }
}
