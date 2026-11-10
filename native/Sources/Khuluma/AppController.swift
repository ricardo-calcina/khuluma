import AppKit
import Foundation
import KhulumaCore

/// Menu-bar app: hotkey → chime + capture → transcription and cleanup →
/// paste/send. Owns the take's lifecycle and the app's state; the work of a
/// take is in `TakePipeline`, persistence in `TakePersister`, the menu in
/// `StatusMenu`.
final class AppController: NSObject, NSApplicationDelegate {
  /// If no audio has arrived this long after the engine started, chime
  /// anyway (and log it) rather than leave the press unanswered.
  private static let chimeFallback: TimeInterval = 0.75

  private lazy var menu = MainActor.assumeIsolated { StatusMenu(stats: statsModel, settings: settingsModel) }
  private lazy var statsModel = MainActor.assumeIsolated {
    StatsModel { [weak self] in
      // Read fresh each time, so a reload or a hand edit of settings.json counts.
      StatsModel.Source(typingWPM: self?.settingsStore.load().settings.history.typingWpm)
    }
  }
  private lazy var settingsModel = MainActor.assumeIsolated { SettingsModel() }
  private let recorder = AudioRecorder()
  /// Keeps Settings' input list current; nil until launch.
  private var inputMonitor: AudioInputMonitor?
  private let sounds = SoundPlayer()
  private lazy var hotkey = HotkeyMonitor { [weak self] in self?.toggle() }
  /// Hold-to-talk's own shortcut (Settings › Dictation › Hold to talk): its
  /// press starts a `.hold` take, its release finishes or discards it.
  private lazy var holdKey = HotkeyMonitor(signature: 0x4B484C44 /* 'KHLD' */,
                                           onRelease: { [weak self] in self?.holdReleased() }) { [weak self] in
    self?.holdPressed()
  }
  /// While-recording extras: the output mute and the idle-sleep block.
  private let environment = RecordingEnvironment()
  /// The bottom-of-screen marker (off unless Settings turns it on).
  private let hud = RecordingHUD()
  /// Ctrl+Esc cancels a recording. Bound only while
  /// recording, so the combination stays free for other apps otherwise.
  private lazy var cancelHotkey = HotkeyMonitor(signature: 0x4B48434E /* 'KHCN' */) { [weak self] in
    self?.cancelRecording()
  }
  private static let cancelKey = try! HotkeySpec.parse("ctrl+escape")
  /// The shortcut plus the chosen modifier (Shift by default) finishes a take
  /// and pastes without sending. Bound only while recording, like cancel.
  private lazy var pasteOnlyHotkey = HotkeyMonitor(signature: 0x4B48504F /* 'KHPO' */) { [weak self] in
    self?.stopRecording(pasteOnly: true)
  }
  /// One start at a time; a failed start never leaves its marker behind.
  private let starter = TakeStarter()
  /// Settings live in settings.json in the app folder.
  private let settingsStore = SettingsStore.standard()
  /// The model folder resolves through FluidAudio (its shared cache, and
  /// whether a folder holds a complete model).
  private let settingsEnvironment: SettingsEnvironment = {
    var environment = SettingsEnvironment.current()
    environment.defaultModelPath = SpeechModel.defaultPath
    environment.modelAvailable = { SpeechModel.isComplete($0, version: $1) }
    // An unsafe socket folder: no socket at all (takes find the daemon
    // unreachable and are kept in recovered; the supervisor says why).
    environment.defaultSocketPath = AppController.daemonSocket.issue == nil ? AppController.daemonSocket.resolved.path : ""
    return environment
  }()
  /// The app daemon's socket, resolved and checked once per launch.
  private static let daemonSocket = DaemonSocketPath.prepared(support: AppRuntimePaths.support)
  /// Reads the settings as AppConfig; safe on any queue.
  private var loadConfig: @Sendable () -> AppConfig {
    let store = settingsStore, environment = settingsEnvironment
    return { store.appConfig(environment: environment) }
  }
  /// Set once the import has run: transcription, delivery and persistence of takes.
  private var pipeline: TakePipeline?
  private var config: AppConfig?
  private var take: Take?
  /// Set once Quit has begun: the hotkey no longer starts new takes.
  private var quitting = false
  private var status = ActivityStatus() { didSet { refreshStatus() } }
  private let work = DispatchQueue(label: "khuluma.work", qos: .userInitiated)
  private let recovered = RecoveredTakes.standard
  private var recoveryRunning = false
  /// Asked for while a recovery pass was running: one more pass after it.
  private var recoveryRerun = false
  private let settingsQueue = DispatchQueue(label: "khuluma.settings", qos: .userInitiated, attributes: .concurrent)
  /// Where take markers go: the processing dir.
  private var markerDirectory: String { config?.transcription.processingDir ?? TakeMarker.defaultDirectory }
  /// Marker dirs already swept for a previous run's leftovers.
  private var sweptMarkerDirectories: Set<String> = []
  /// Keeps the app's daemon warm; nil until initialization.
  private var supervisor: DaemonSupervisor?
  /// The bundled khulumad this app runs (stopped on quit).
  private var daemon: DaemonProcess?
  /// First-run model download.
  private var models: ModelProvisioner?
  /// Why supervision is off, as last logged ("" = on).
  private var supervisionNote: String?
  private var supervisedTarget: DaemonSupervisor.Target?
  /// A hotkey change read while a take was recording, applied when it ends.
  private var pendingHotkey: HotkeySpec?
  /// Takes whose transcription timed out, for Retry/Discard.
  private let timedOut = TimedOutTakes.standard
  /// The last active app other than Khuluma: a take started with Khuluma in
  /// front is meant for it.
  private var lastExternalApp: NSRunningApplication?
  /// Every take stopped for Quit whose audio couldn't be written yet.
  private var unsaved: [UnsavedTake] = []
  /// Stopped takes until they end (queued or being transcribed): Quit saves
  /// their audio, in case the drain runs out before they finish.
  private let inFlight = InFlightTakes(store: .standard)
  /// Made on first open, then reused.
  private var statsWindow: StatsWindowController?
  /// Finder's Local and Cloud transcription services.
  private var quickAction: QuickActionService?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A previous run that crashed mid-take may have left the output muted.
    environment.restoreAfterLaunch()
    connectMenu()
    registerQuickAction()
    menu.install()
    MainActor.assumeIsolated { AppMainMenu.install { [weak self] in self?.showStats(settings: true) } }
    sweepStaleMarkers()
    Log.write("launch: Khuluma \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
              + ", start at login \(LoginItem.text(LoginItem.status))")

    let settings = settingsModel
    recorder.preferredInput = { settings.microphone }
    recorder.onFallbackChange = { settings.reportMicrophoneFallback($0) }
    recorder.prepare()
    recorder.onConfigurationChange = { [weak self] in self?.handleDeviceChange() }
    inputMonitor = AudioInputMonitor { settings.adoptAudioInputs($0) }
    // A new choice, or the chosen device coming and going, rebuilds the
    // engine while idle; during a take it waits for the take to end.
    settings.observeMicrophoneChoice { [weak self] in self?.recorder.inputChoiceChanged() }
    AudioRecorder.requestPermission { [weak self] granted in
      if !granted { Log.write("permission: microphone denied"); self?.menu.showPermission(PermissionPolicy.microphoneNotice) }
    }
    if !Deliverer.isTrusted(prompt: true) {
      Log.write("permission: accessibility not granted yet (prompted)")
    }
    if let notice = Permissions.checkKeyboardAtLaunch() { menu.showPermission(notice) }

    // An unreadable vocabulary file doesn't hold takes back: they are
    // cleaned without it, and the log says so on every take until it's fixed.
    TextPipeline.reportInvalidVocabulary = { error in
      Log.write("vocabulary: vocabulary.json is invalid, cleaning without it (fix it in Vocabulary): \(error.localizedDescription)")
    }
    // The one-time import of the CLI's data (settings included) runs before
    // settings load and before the persister's replay. Off main: it touches
    // the disk.
    settingsQueue.async { [weak self] in
      let imported = LegacyImport.run()
      Log.write("import: \(imported.logLine)")
      TimedOutTakes.report = { Log.write($0) }
    // Timed-out takes from builds that kept them in $TMPDIR.
      let moved = TimedOutTakes.standard.adoptLegacy(from: TimedOutTakes.legacyDirectory)
      if moved > 0 { Log.write("timed-out: moved \(moved) file(s) from \(TimedOutTakes.legacyDirectory.path) into the app folder") }
      DispatchQueue.main.async {
        guard let self, !self.quitting else { return }
        self.finishInitialization()
      }
    }
  }

  /// Serves the Quick Action; macOS launches the app for it if needed. Its
  /// files wait until initialization (the import) is done and while a take
  /// is recording or in flight.
  private func registerQuickAction() {
    // An isolated run must not register Services for the whole login.
    guard !AppRuntimePaths.isolated else { return }
    let load = loadConfig
    let service = QuickActionService(loadConfig: { load() })
    service.dictationBusy = { [weak self] in
      guard let self, !self.quitting else { return false }
      return self.pipeline == nil || self.take != nil || self.inFlight.count > 0
    }
    service.localDaemon = { [weak self] in self?.daemon }
    service.prepareLocalModel = { [weak self] in
      self?.models?.ensure(configured: nil, fallback: SpeechModel.defaultPath)
    }
    quickAction = service
    NSApp.servicesProvider = service
    NSUpdateDynamicServices()
  }

  private func finishInitialization() {
    let pipeline = TakePipeline(persister: TakePersister(), loadConfig: loadConfig) { [weak self] in
      self?.supervisor?.trigger(.unreachable)
    }
    self.pipeline = pipeline
    let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, work in
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
    // The app's own daemon on its own socket.
    let (socket, socketIssue) = Self.daemonSocket
    if socket.isFallback {
      Log.write("daemon: the app folder's path is too long for a socket; using \(socket.path)")
    }
    let refusal = socketIssue.map { "unsafe socket folder: \($0)" }
    if let refusal { Log.write("daemon: \(refusal); not starting or connecting") }
    let daemon = DaemonProcess(
      binary: DaemonProcess.locateBinary(), socketPath: socket.path, support: AppRuntimePaths.support,
      logDirectory: AppRuntimePaths.logs, environment: .live(schedule: schedule), refusal: refusal,
      log: { Log.write($0) })
    self.daemon = daemon
    // A restarted daemon has no model loaded: warm it now, not on the next take.
    daemon.onRestart = { [weak self] in
      DispatchQueue.main.async { self?.supervisor?.trigger(.restarted) }
    }
    models = ModelProvisioner(environment: SpeechModel.environment) { [weak self] state in
      // The run loop, not main.async: the menu may be open, showing progress.
      onMainRunLoop { self?.showModelState(state) }
    }
    var supervision = DaemonSupervisor.Environment(
      probe: { path, timeout in DaemonClient(socketPath: path).status(timeout: timeout) },
      warmup: DaemonSupervisor.ownedWarmup(process: daemon),
      schedule: schedule)
    supervision.adopt = { _ = daemon.ensureRunning() }
    supervisor = DaemonSupervisor(
      environment: supervision,
      onChange: { [weak self] state, line in
        Log.write("supervisor: \(line)")
        onMainRunLoop { self?.showDaemonState(state) }
      })
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.supervisor?.trigger(.wake) }
    trackExternalApps()
    reloadSettings()
    pipeline.persister.replayLeftovers()
    refreshTimedOutItems()
    // `-KhulumaOpenStats YES`: open Stats at launch (for checking the window).
    if AppRuntimePaths.defaults.bool(forKey: "KhulumaOpenStats") {
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
    menu.onShowSettings = { [weak self] in self?.showStats(settings: true) }
    settingsModel.onReload = { [weak self] in self?.reloadSettings(feedback: true) }
    settingsModel.onOpenConfig = { [weak self] in
      guard let store = self?.settingsStore else { return }
      try? store.ensureFile()
      NSWorkspace.shared.open(store.url)
    }
    settingsModel.onToggleLogin = { [weak self] in self?.toggleStartAtLogin() }
    settingsModel.onSave = { [weak self] key, value in self?.saveSetting(key, value: value) }
    let vocabulary = VocabularyStore(root: AppRuntimePaths.support)
    settingsModel.onLoadVocabulary = { try vocabulary.show() }
    settingsModel.onSaveVocabulary = { try vocabulary.save($0) }
    settingsModel.onValidateVocabulary = { try vocabulary.validate($0) }
    settingsModel.onLoadRecentDictations = {
      RecentDictations.raw(history: AppRuntimePaths.support.appendingPathComponent("history", isDirectory: true))
    }
    settingsModel.onShortcutRecordingChange = { [weak self] recording in
      guard let self else { return }
      if recording {
        self.hotkey.unregister()
        self.holdKey.unregister()
      } else {
        if self.pipeline != nil, self.hotkey.binding == nil, let spec = try? HotkeySpec.parse(self.config?.hotkey ?? "") {
          self.registerHotkey(spec)
        }
        self.syncHoldHotkey()
      }
    }
    settingsModel.onHoldHotkeyChange = { [weak self] in self?.syncHoldHotkey() }
    settingsModel.onWhileRecordingChange = { [weak self] in self?.refreshStatus() }
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
  /// finish as usual; each one that settles drops its saved copy. They and
  /// persistence get up to 30 s; whatever doesn't finish is recovered at the
  /// next launch (saved audio, spooled records). Before replying, every
  /// take's audio is checked to be on disk (`finishQuitting`).
  /// Clicking the Dock icon (only there while the window is open) brings the window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showStats() }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateLater }
    Log.write("quit: requested; saving recordings and draining")
    if take != nil || !unsaved.isEmpty {
      guard saveRecordingForQuit() else {
        // Couldn't write the audio: stay open rather than lose a take. Only
        // the explicit "Discard … and quit" menu item gives it up.
        showDiscardUnsaved()
        fail("couldn't save \(unsaved.count) recording\(unsaved.count == 1 ? "" : "s") for quitting; Quit retries")
        return .terminateCancel
      }
    }
    saveInFlightForQuit()
    guard inFlight.held == 0 else {
      // Takes already over whose audio still can't be written: as above.
      showDiscardUnsaved()
      fail("couldn't save \(inFlight.held) recording\(inFlight.held == 1 ? "" : "s") for quitting; Quit retries")
      return .terminateCancel
    }
    return terminateAfterDraining()
  }

  /// Last chance to put the output back and drop the wake block; `end` is
  /// idempotent, so the take paths that already called it do nothing here.
  func applicationWillTerminate(_ notification: Notification) {
    environment.end()
  }

  /// Offers "Discard … and quit" for every take whose audio is only in memory.
  private func showDiscardUnsaved() {
    let count = unsaved.count + inFlight.held
    menu.showDiscardUnsaved(count == 0 ? nil : "Discard \(count) unsaved recording\(count == 1 ? "" : "s") and quit")
  }

  /// Writes the audio of takes still queued or being transcribed. One that
  /// can't be written isn't lost yet: it may still finish in the drain, and
  /// `finishQuitting` tries again before replying.
  private func saveInFlightForQuit() {
    guard inFlight.count > 0 else { return }
    let (saved, failed) = inFlight.saveAll()
    Log.write("quit: saved \(saved) take(s) still being transcribed to recovered/ (each copy goes once its take settles)"
              + (failed > 0 ? "; \(failed) couldn't be written yet" : ""))
  }

  private func discardUnsavedAndQuit() {
    Log.write("quit: discarding \(unsaved.count + inFlight.held) unsaved recording(s) at the user's request")
    unsaved.forEach { $0.marker?.remove() }
    unsaved.removeAll()
    inFlight.discardHeld()
    menu.showDiscardUnsaved(nil)
    NSApp.terminate(nil)
  }

  private func terminateAfterDraining() -> NSApplication.TerminateReply {
    quitting = true
    // Whichever comes first, the drain or the 30 s timeout, decides; the
    // other finds the semaphore taken and does nothing.
    let replied = DispatchSemaphore(value: 1)
    let decide = { [weak self] (drained: Bool) in
      guard replied.wait(timeout: .now()) == .success else { return }
      guard let self else { return NSApp.reply(toApplicationShouldTerminate: true) }
      self.finishQuitting(drained: drained)
    }
    let persistQueue = pipeline?.persister.queue
    // Replies go through the main run loop, not the main dispatch queue:
    // while AppKit waits for the reply it may be inside a main-queue drain
    // (e.g. terminate called from a dispatch callout), where main.async
    // blocks would never run.
    work.async {
      guard let persistQueue else { return onMainRunLoop { decide(true) } }
      persistQueue.async { onMainRunLoop { decide(true) } }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) { onMainRunLoop { decide(false) } }
    return .terminateLater
  }

  /// The last check before quitting: every take's audio must be on disk.
  /// Takes Quit couldn't write are tried again: those still running, and
  /// those that ended meanwhile (`inFlight` holds their audio). If any still
  /// can't be written, Khuluma stays open rather than lose them.
  private func finishQuitting(drained: Bool) {
    let failed = inFlight.saveAll().failed
    guard failed == 0 else {
      quitting = false
      NSApp.reply(toApplicationShouldTerminate: false)
      showDiscardUnsaved()
      fail("couldn't save \(failed) recording\(failed == 1 ? "" : "s") for quitting; Quit retries")
      return
    }
    if !drained {
      Log.write("quit: pending work did not finish within 30s; quitting (saved audio and spooled takes are recovered at next launch)")
    }
    // SIGTERM our khulumad; it drains in-flight work itself. Waits ≤ 2 s.
    daemon?.stop(timeout: 2)
    Log.write("quit: done" + (drained ? "" : " (after the 30s limit)"))
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  /// Stops the take in progress for Quit and writes its audio (and any
  /// earlier unsaved takes) to the recovery folder before anything else,
  /// then queues transcriptions that only copy the text. Returns false if
  /// any audio couldn't be written; those takes stay in `unsaved`.
  private func saveRecordingForQuit() -> Bool {
    environment.end()
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
    showDiscardUnsaved()
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
    guard !recoveryRunning else {
      recoveryRerun = true
      return
    }
    let leftovers = leftoverTakes()
    guard !leftovers.isEmpty else { return }
    // ElevenLabs: try the configured route even when the key isn't visible
    // to the app (a zshrc key); a failure keeps the take in recovered.
    guard config.nativePipelineBlocker == nil || config.transcription.provider == "elevenlabs" else {
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
        defer {
          if self.recoveryRerun {
            self.recoveryRerun = false
            if let config = self.config { self.recoverLeftoverTakes(config: config) }
          }
        }
        if remaining > 0 {
          self.menu.showRecovered("Saved dictations waiting (\(remaining)): Show in Finder", action: true)
        } else if done > 0 {
          self.menu.showRecovered(
            "Recovered \(done) dictation\(done == 1 ? "" : "s") into history (see Stats)", action: false)
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
      guard canStart() else { return }
      startRecording(hotkeyAt: hotkeyAt, mode: .toggle)
    } else if take?.mode == .hold {
      // The hold key's release may have been swallowed; the toggle press
      // finishes the take rather than leaving it recording.
      Log.write("toggle: finished a hold-to-talk take")
      stopRecording()
    } else {
      stopRecording()
    }
  }

  /// The shared start gate for the toggle and hold keys.
  private func canStart() -> Bool {
    guard !quitting else { return false }
    guard !settingsModel.saving else { return false }
    guard !starter.isStarting else {
      Log.write("start: ignored a press while the microphone was still starting")
      return false
    }
    // A denied microphone still delivers buffers, of silence: don't start.
    if let notice = PermissionPolicy.microphoneNotice(for: Permissions.microphoneStatus) {
      Log.write("start: refused, microphone access denied")
      sounds.play(.error)
      menu.showPermission(notice)
      fail("microphone access is off")
      return false
    }
    menu.clearPermission(.microphone)
    return true
  }

  /// The hold key went down. A press during a toggle take is ignored; a
  /// second press of a hold take means its release was lost, so finish it.
  private func holdPressed() {
    let hotkeyAt = monotonicMs()
    if let take {
      if take.mode == .hold {
        Log.write("hold: pressed again, finishing the take")
        stopRecording()
      }
      return
    }
    guard canStart() else { return }
    Log.write("hold: pressed, starting a hold-to-talk take")
    startRecording(hotkeyAt: hotkeyAt, mode: .hold)
  }

  /// The hold key came up. Ignored unless the take in progress is a hold
  /// take; a tap discards it, a hold finishes it after a short tail.
  private func holdReleased() {
    guard let take, take.mode == .hold else { return }
    let heldMs = Int(monotonicMs() - take.hotkeyAt)
    switch HoldPolicy.onRelease(heldMs: heldMs) {
    case .discard:
      cancelHotkey.unregister()
      pasteOnlyHotkey.unregister()
      _ = recorder.stop()
      take.marker?.remove()
      self.take = nil
      environment.end()
      // The chime never played: nothing sounded, so stay silent. If it did,
      // say the take was discarded.
      if !take.chime.fire() { sounds.play(.cancel) }
      status.recordingCancelled()
      Log.write("hold: released after \(heldMs)ms, discarded")
      applyPendingHotkey()
    case .finish(let tailMs):
      Log.write("hold: released after \(heldMs)ms, finishing in \(tailMs)ms")
      let id = take.id
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(tailMs) / 1000) { [weak self] in
        // A cancel or a device-change stop in between ends this take; there
        // must be no second stop on whatever take is current then.
        guard let self, self.take?.id == id else { return }
        self.stopRecording()
      }
    }
  }

  private func startRecording(hotkeyAt: Double, mode: TakeMode) {
    // The chime is the cue to speak, so it plays only once the first audio
    // buffer has arrived: words spoken at the chime are always captured.
    // (It used to play before the engine started, ~120 ms before capture.)
    let chime = OneShot()
    let takeID = UUID()
    let sounds = self.sounds
    let environment = self.environment
    // Mute other audio only after the start chime, so it stays audible.
    // Without a loaded start sound the mute happens when the take starts.
    let muteDelay = settingsModel.muteWhileRecording ? sounds.duration(.start) : nil
    let playChime: (String) -> Void = { how in
      guard chime.fire() else { return }
      sounds.play(.start) { playMs in
        Log.write(String(format: "start: chime %@, hotkey→chime ≈ %.1fms (play() %.1fms)",
                         how, monotonicMs() - hotkeyAt, playMs))
      }
      if let muteDelay {
        DispatchQueue.main.asyncAfter(deadline: .now() + muteDelay + 0.05) {
          environment.mute(takeID: takeID)
        }
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
        // Recording matters more: the marker only shows a take in progress.
        Log.write("markers: could not publish a take marker in \(directory); recording anyway")
      }
      return marker
    }, capture: { try recorder.start(onFirstAudio: { playChime("at first audio") }) })
    switch outcome {
    case .started(let engineMs, let marker):
      let startedAt = monotonicMs()
      take = Take(
        id: takeID,
        mode: mode,
        hotkeyAt: hotkeyAt,
        startedAt: startedAt,
        startedEpochMs: Int(Date().timeIntervalSince1970 * 1000),
        startupMs: Int((startedAt - hotkeyAt).rounded()),
        originalApp: original,
        retargeted: retargeted,
        settings: SettingsFetch(queue: settingsQueue, load: loadConfig),
        marker: marker,
        chime: chime
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.chimeFallback) {
        playChime("with no audio yet after \(Int(Self.chimeFallback * 1000))ms")
      }
      environment.begin(takeID: takeID, keepAwake: settingsModel.keepAwakeWhileRecording)
      // No start sound loaded: mute now rather than after the chime.
      if settingsModel.muteWhileRecording && muteDelay == nil {
        environment.mute(takeID: takeID)
      }
      status.recordingStarted()
      do {
        // A toggle bound to the same keys already stops the take.
        if hotkey.binding != Self.cancelKey { try cancelHotkey.register(Self.cancelKey) }
      } catch {
        Log.write("hotkey: \(Self.cancelKey.display) to cancel is unavailable this take: \(error.localizedDescription)")
      }
      // The paste-without-sending stop key applies to toggle takes only.
      if mode == .toggle, let binding = hotkey.binding,
         let pasteOnly = settingsModel.pasteOnlyModifier.stopShortcut(for: binding) {
        do { try pasteOnlyHotkey.register(pasteOnly) } catch {
          Log.write("hotkey: \(pasteOnly.display) to paste without sending is unavailable this take: \(error.localizedDescription)")
        }
      }
      Log.write(String(format: "start: engine.start %.1fms, hotkey→capturing %.1fms, app=%@, input=%@",
                       engineMs, startedAt - hotkeyAt, original?.localizedName ?? "-", recorder.inputName))
      // While you speak: make sure the daemon is up with the model loaded
      // (a ping when it is; a start or model load when it isn't).
      supervisor?.trigger(.recordingStart)
    case .busy:
      Log.write("start: ignored a press while the microphone was still starting")
    case .failed(let error):
      // The marker is already gone.
      chime.cancel()
      sounds.play(.error)
      fail("could not start recording: \(error.localizedDescription)")
    }
  }

  private func stopRecording(pasteOnly: Bool = false) {
    guard var take else { return }
    // "Stop → delivered" starts here, before the engine is torn down.
    let stopAt = monotonicMs()
    take.chime.cancel()
    environment.end()
    cancelHotkey.unregister()
    pasteOnlyHotkey.unregister()
    if pasteOnly {
      take.pasteOnly = true
      Log.write("stop: paste-only shortcut, this take will not be sent")
    }
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
    environment.end()
    cancelHotkey.unregister()
    pasteOnlyHotkey.unregister()
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
      // Still starting (the import runs first): never drop the samples.
      // Saved like a quit's take and transcribed once settings are loaded.
      take.marker?.remove()
      let takeId = inFlight.add(samples: samples)
      let kept: Bool
      do { _ = try inFlight.keep(takeId); kept = true } catch {
        kept = false
        Log.write("pipeline: could not save the recording yet (held until Quit): \(error.localizedDescription)")
      }
      var line = TakeLog()
      line.add("path", "none")
      line.add("outcome", "failed")
      line.add("record", recordMs)
      line.add("error", "not_ready")
      line.add("kept", kept ? 1 : 0)
      Log.write(line.line)
      if kept { menu.showRecovered("Saved recording waiting: Show in Finder", action: true) }
      finishProcessing(error: "Khuluma was still starting; recording saved" + (kept ? "" : " until Quit"))
      return
    }
    let frontmostAtStop = NSWorkspace.shared.frontmostApplication?.localizedName
    let cachedConfig = self.config
    // In memory only until the take ends: Quit saves it from here.
    let takeId = inFlight.add(samples: samples)
    work.async { [weak self, inFlight] in
      // Every path below is synchronous on this queue: the take is over when
      // it returns. A copy Quit saved is deleted only if the take settled.
      var settled = false
      defer {
        take.marker?.remove()
        if settled { inFlight.finish(takeId) } else { inFlight.release(takeId) }
      }
      guard let self else { return }
      take.marker?.update(.processing)
      // Settings fetched during the recording; usually ready long before
      // stop. Without them the take is kept, not guessed at.
      var fresh: AppConfig?
      var problem: String?
      switch take.settings?.wait(timeout: 20) ?? .unavailable("no settings fetch") {
      case .config(let config): fresh = config
      case .unavailable(let reason): problem = reason
      }
      if let fresh, fresh != cachedConfig {
        DispatchQueue.main.async { self.adopt(fresh) }
      }
      // The app history records: "restore" uses the app from recording start;
      // "current" uses whatever is frontmost when processing begins. A
      // retargeted take is delivered to its original app, so it's that one.
      let appName = DeliveryTarget.deliveryApp(pasteTarget: fresh?.inline.pasteTarget, retargeted: take.retargeted,
                                               original: take.originalApp?.localizedName, frontmostAtStop: frontmostAtStop)
      let result: TakeResult
      switch TakeRoute.decide(config: fresh, problem: problem) {
      case .keep(let kept):
        // No model yet, unusable settings: the take waits in recovered/.
        self.keepTake(takeId: takeId, recordMs: recordMs, kept: kept)
        return
      case .scribe:
        // ElevenLabs Scribe. A failure keeps the take (saved like any
        // failed one below) and counts nothing.
        guard let fresh else { return }
        result = pipeline.processWithScribe(samples: samples, take: take, takeId: takeId, recordMs: recordMs,
                                            appName: appName, config: fresh, stopAt: stopAt)
      case .native:
        guard let fresh else { return }
        switch pipeline.processNatively(samples: samples, take: take, takeId: takeId, recordMs: recordMs, appName: appName,
                                        config: fresh, stopAt: stopAt) {
        case .handled(let handled): result = handled
        case .kept(let kept):
          self.keepTake(takeId: takeId, recordMs: recordMs, kept: kept)
          return
        }
      }
      settled = result.settlesAudio
      self.keepAudioIfUnsettled(result, takeId: takeId)
      DispatchQueue.main.async { self.finish(result) }
    }
  }

  /// Every ending that leaves the audio unsettled (failed, paste failed or
  /// delivered without a spooled record, timed out without a kept copy)
  /// saves the recording for recovery; if that can't be written it is held
  /// until Quit. Runs on `work`.
  private func keepAudioIfUnsettled(_ result: TakeResult, takeId: String) {
    guard result.keepsAudio else { return }
    if (try? inFlight.keep(takeId)) != nil {
      DispatchQueue.main.async { self.menu.showRecovered("Saved recording waiting: Show in Finder", action: true) }
    } else {
      Log.write("pipeline: unsettled recording held until Quit (could not save audio)")
    }
  }

  /// Shows how a take ended.
  private func finish(_ result: TakeResult) {
    switch result {
    case .delivered:
      sounds.play(.stop)
      menu.clearPermission(.keyboard)
      finishProcessing(error: nil)
    case .noSpeech:
      finishProcessing(error: nil, note: "No speech detected")
    case .failed(let message), .pasteFailed(let message, _):
      sounds.play(.error)
      if let notice = PermissionPolicy.notice(forFailure: message) { menu.showPermission(notice) }
      finishProcessing(error: message)
    case .timedOut(let message, _):
      sounds.play(.error)
      refreshTimedOutItems()
      finishProcessing(error: message)
    }
  }

  /// The take can't be transcribed now (the model is still downloading, the
  /// daemon or model isn't ready, transcription failed, settings unusable):
  /// it is saved to recovered/ and transcribed into history once the
  /// supervisor reports ready, settings change or the app next launches.
  /// Nothing retries it in a loop: a permanent condition just waits. If it
  /// can't be written it stays in memory (held by `inFlight`), and Quit
  /// writes it. Runs on `work`.
  private func keepTake(takeId: String, recordMs: Int, kept keptTake: KeptTake) {
    let reason = keptTake.reason, category = keptTake.category
    let kept: Bool
    do {
      let url = try inFlight.keep(takeId)
      Log.write("pipeline: \(reason); saved the recording to \(url.lastPathComponent)")
      kept = true
    } catch {
      Log.write("pipeline: \(reason); could not save the recording: \(error.localizedDescription)")
      kept = false
    }
    var line = TakeLog()
    line.add("path", "none")
    line.add("outcome", "failed")
    line.add("record", recordMs)
    line.add("error", category)
    line.add("kept", kept ? 1 : 0)
    Log.write(line.line)
    // Settings as of now, not as of the take (the model may have arrived).
    let fresh = kept ? loadConfig() : nil
    DispatchQueue.main.async {
      if kept {
        self.menu.showRecovered("Saved dictations waiting (\(self.leftoverTakes().count)): Show in Finder", action: true)
      }
      if let fresh {
        switch KeptTakeFollowUp.decide(settingsChanged: fresh != self.config,
                                       supervisorReady: self.supervisor?.currentState.isReady == true) {
        case .applySettings: self.apply(fresh)
        case .recoverNow: self.recoverLeftoverTakes(config: fresh)
        case .waitForReady: break
        }
      }
      self.sounds.play(.error)
      let shown = reason.prefix(1).uppercased() + reason.dropFirst()
      self.finishProcessing(error: shown + (kept ? " (recording saved)" : " (recording kept until Quit)"))
    }
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
    hud.update(phase: status.phase, recordingStartedAt: take?.startedAt,
               enabled: settingsModel.showRecordingHUD)
    menu.show(status, recording: take != nil)
    settingsModel.recording = take != nil || starter.isStarting || status.processing > 0
  }

  // MARK: - Settings

  private func reloadSettings(feedback: Bool = false) {
    // Nothing loads or registers until the import and pipeline are ready.
    guard pipeline != nil else {
      if feedback { settingsModel.finished(error: "Khuluma is still starting.") }
      return
    }
    if feedback { settingsModel.saving = true }
    let load = loadConfig
    work.async { [weak self] in
      // Never fails: an invalid settings.json falls back (see showConfigStatus).
      let config = load()
      DispatchQueue.main.async {
        self?.apply(config)
        if feedback {
          self?.settingsModel.finished()
          self?.settingsModel.message = "Settings reloaded"
        }
      }
    }
  }

  /// History retention for the persister, from settings.json.
  private func adoptPersistence(_ config: AppConfig) {
    pipeline?.persister.adopt(config, history: settingsStore.load().settings.history)
  }

  /// Logged once: an isolated run ignoring a model folder in real data.
  private var warnedForbiddenModel = false

  private func apply(_ config: AppConfig) {
    if !warnedForbiddenModel {
      let configured = settingsStore.load().settings.transcription.modelPath
      if !configured.isEmpty, settingsEnvironment.isForbiddenModelPath(settingsEnvironment.expand(configured)) {
        warnedForbiddenModel = true
        Log.write("settings: isolated run ignores model_path \(configured) (real data); using the isolated default")
      }
    }
    let firstSettings = self.config == nil
    self.config = config
    adoptPersistence(config)
    settingsModel.adopt(config)
    sweepStaleMarkers()
    sounds.load(from: config)
    showConfigStatus(config)
    recoverLeftoverTakes(config: config)
    configureSupervision(config, trigger: firstSettings ? .launch : .settings)
    do {
      let spec = try HotkeySpec.parse(config.hotkey)
      Log.write("settings: hotkey \(spec.display), settings.json (\(config.config.source)), pipeline "
                + (config.nativePipelineBlocker.map { "takes kept (\($0))" } ?? "ready"))
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
      fail("hotkey \"\(config.hotkey)\": \(error)")
    }
    syncHoldHotkey()
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
    adoptPersistence(fresh)
    settingsModel.adopt(fresh)
    sweepStaleMarkers()
    configureSupervision(fresh, trigger: .settings)
    sounds.load(from: fresh)
    if pipelineChanged {
      Log.write("settings: pipeline " + (fresh.nativePipelineBlocker.map { "takes kept (\($0))" } ?? "ready"))
    }
  }

  /// Warns in the menu (and log) while settings.json doesn't parse.
  private func showConfigStatus(_ config: AppConfig) {
    let status = config.config
    guard let error = status.error else {
      menu.showConfigWarning(nil)
      return
    }
    let using = status.source == "last_good"
      ? "using the last valid settings"
      : "using defaults, paste without sending"
    let what = status.source == SettingsStore.importedDefaultsSource || error.hasPrefix("settings were not imported")
      ? "settings not imported" : "settings.json invalid"
    menu.showConfigWarning("⚠︎ \(what): \(using)")
    Log.write("settings: \(what) (\(error)); \(using)")
  }

  /// Binds the hotkey; if the new one can't be registered, the old binding
  /// stays in effect. Returns whether `spec` is now bound.
  @discardableResult
  private func registerHotkey(_ spec: HotkeySpec) -> Bool {
    do {
      try hotkey.register(spec)
      return true
    } catch {
      let kept = hotkey.binding.map { "; keeping \($0.display)" } ?? ""
      fail("\(error.localizedDescription)\(kept)")
      return false
    }
  }

  private func applyPendingHotkey() {
    guard take == nil, !starter.isStarting else { return }
    if let spec = pendingHotkey {
      pendingHotkey = nil
      if registerHotkey(spec) { Log.write("settings: hotkey changed to \(spec.display)") }
    }
    syncHoldHotkey()
  }

  /// Binds or unbinds the hold-to-talk key from the current preference.
  /// Never mid-take or mid-start: a change waiting then is picked up by
  /// `applyPendingHotkey` when the take ends. A failed registration keeps
  /// the old binding, like `registerHotkey`.
  private func syncHoldHotkey() {
    guard take == nil, !starter.isStarting else { return }
    let text = settingsModel.holdHotkey
    guard !text.isEmpty else {
      if holdKey.binding != nil { holdKey.unregister() }
      return
    }
    // Settings validates before storing; an unparseable leftover just
    // leaves the key unbound.
    guard let spec = try? HotkeySpec.parse(text) else {
      holdKey.unregister()
      return
    }
    do {
      try holdKey.register(spec)
    } catch {
      let kept = holdKey.binding.map { "; keeping \($0.display)" } ?? ""
      fail("\(error.localizedDescription)\(kept)")
    }
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
    // No model yet: get it (FluidAudio's cache), without blocking takes.
    if config.transcription.provider == "parakeet", config.transcription.modelPath == nil {
      models?.ensure(configured: nil, fallback: SpeechModel.defaultPath)
    }
    guard target != supervisedTarget else { return }
    supervisedTarget = target
    supervisor?.configure(target)
    if target == nil {
      menu.showDaemon(models?.currentState.menuTitle)
    } else {
      supervisor?.trigger(trigger)
    }
  }

  /// Download progress in the menu; once the model is in, settings are
  /// re-resolved so supervision starts, and saved takes are retried.
  private func showModelState(_ state: ModelProvisioner.State) {
    switch state {
    case .present(let path):
      Log.write("model: ready at \(path)")
      menu.showDaemon(nil)
      // A Local Finder request can provision Parakeet while dictation uses
      // Scribe. That request must not trigger cloud recovery of old dictation.
      guard config?.transcription.provider == "parakeet" else { return }
      reloadSettings()
      if let config { recoverLeftoverTakes(config: config) }
    case .downloading:
      if supervisedTarget == nil { menu.showDaemon(state.menuTitle) }
    case .failed(let reason):
      Log.write("model: download failed: \(reason)")
      if supervisedTarget == nil { menu.showDaemon(state.menuTitle) }
    case .unknown:
      break
    }
  }

  private func showDaemonState(_ state: DaemonSupervisor.State) {
    guard config?.transcription.provider != "elevenlabs" else { menu.showDaemon(nil); return }
    switch state {
    case .unknown:
      menu.showDaemon(models?.currentState.menuTitle)
    case .ready:
      menu.showDaemon(nil)
      // Saved takes that failed while the daemon was down or loading.
      if let config { recoverLeftoverTakes(config: config) }
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
  private let pasteQueue = DispatchQueue(label: "khuluma.paste", qos: .userInitiated)

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
          if let notice = PermissionPolicy.notice(forFailure: message) { self.menu.showPermission(notice) }
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
    // Khuluma never takes focus, so this is the app the user chose Paste in.
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
        var spooled = true
        if var record = pending.record {
          let deliveredDate = Date()
          record.delivered = true
          record.deliveredAtMs = Int(deliveredDate.timeIntervalSince1970 * 1000)
          record.deliveredLocalDate = LocalDate.string(for: deliveredDate)
          spooled = pipeline.persister.persist(record)
        }
        // The recording goes only once the record is durably spooled.
        if spooled {
          pipeline.timedOut.remove(pending.entry)
        } else {
          Log.write("retry: pasted, but the record could not be spooled; the recording is kept")
        }
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
      settingsModel.failed = false
      settingsModel.message = "Start at Login: \(LoginItem.text(LoginItem.status))"
    } catch {
      Log.write("login: could not change start at login: \(error.localizedDescription)")
      fail("could not change Start at Login: \(error.localizedDescription)")
      settingsModel.finished(error: error.localizedDescription)
    }
    menu.showLogin(LoginItem.status)
  }

  /// Remembers the last active app other than Khuluma (see `startRecording`).
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

  private func showStats(settings: Bool = false) {
    MainActor.assumeIsolated {
      let window = statsWindow ?? StatsWindowController(
        model: statsModel, settings: settingsModel)
      statsWindow = window
      settingsModel.loginStatus = LoginItem.status
      window.show(settings: settings)
    }
  }

  private func saveSetting(_ key: String, value: String) {
    guard pipeline != nil else {
      settingsModel.finished(error: "Khuluma is still starting.")
      return
    }
    guard take == nil, !starter.isStarting, status.processing == 0 else {
      settingsModel.finished(error: "Finish the recording before changing settings.")
      return
    }
    let previousHotkey = hotkey.binding ?? (try? HotkeySpec.parse(config?.hotkey ?? ""))
    // The toggle shortcut can't take over the hold-to-talk key.
    if key == "app.hotkey",
       let hold = holdKey.binding ?? (try? HotkeySpec.parse(settingsModel.holdHotkey)),
       let spec = try? HotkeySpec.parse(value), spec == hold {
      settingsModel.finished(error: "\(hold.display) is your hold-to-talk shortcut; clear it or choose another")
      return
    }
    if key == "app.hotkey" {
      do { try hotkey.register(HotkeySpec.parse(value)) }
      catch { settingsModel.finished(error: error.localizedDescription); return }
    }
    work.async { [weak self] in
      guard let self else { return }
      let store = self.settingsStore
      let result = Result { try store.set(key, value: value) }.map { _ in self.loadConfig() }
      // .common modes: the menu's Auto-send switch saves while the menu tracks.
      onMainRunLoop {
        switch result {
        case .success(let config):
          self.apply(config)
          self.settingsModel.finished(error: nil)
        case .failure(let error):
          if key == "app.hotkey", let previousHotkey { self.registerHotkey(previousHotkey) }
          self.settingsModel.finished(error: error.localizedDescription)
        }
      }
    }
  }
}

/// Runs `work` once on the main thread from the run loop, in the common
/// modes (AppKit adds its modal-panel mode, used while it waits for a
/// terminate reply), never from inside a main-queue drain.
func onMainRunLoop(_ work: @escaping () -> Void) {
  let main = CFRunLoopGetMain()
  CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue, work)
  CFRunLoopWakeUp(main)
}
