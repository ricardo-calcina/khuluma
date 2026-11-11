import AppKit
import KhulumaCore

/// Dictation settings come from settings.json; app presentation uses private defaults.
final class SettingsModel: ObservableObject {
  @Published private(set) var config: AppConfig?
  @Published private(set) var iconTheme: StatusIconTheme
  @Published private(set) var pasteOnlyModifier: PasteOnlyModifier
  @Published private(set) var menuFigures: MenuFigures
  @Published private(set) var menuShowsWeek: Bool
  /// Hold-to-talk's own shortcut, "" = off (Settings › Dictation).
  @Published private(set) var holdHotkey: String
  /// Re-paste the newest dictation, "" = off (Settings › Recording).
  @Published private(set) var pasteLastHotkey: String
  @Published private(set) var muteWhileRecording: Bool
  @Published private(set) var keepAwakeWhileRecording: Bool
  @Published private(set) var showRecordingHUD: Bool
  @Published private(set) var liveTranscription: Bool
  /// The chosen input (nil = System Default), as UID and the name it had.
  @Published private(set) var microphone: AudioInput?
  /// Connected inputs, from CoreAudio or sample data in previews.
  @Published private(set) var audioInputs = AudioInputs()
  /// The chosen device the recorder couldn't use (takes use the default).
  @Published private(set) var unusableMicrophoneUID: String?
  @Published var saving = false
  @Published var recording = false
  @Published var message: String?
  @Published var failed = false
  @Published var loginStatus = LoginItem.status
  /// The Settings tab's page. Kept here so it survives tab switches; not saved.
  @Published var page: SettingsPage = .recording {
    didSet { keyDraft = "" }
  }
  /// Where the ElevenLabs key was found (never the key itself).
  @Published private(set) var keySource: ScribeCredential.Source?
  /// What is typed in the API key field; cleared on save.
  @Published var keyDraft = ""
  var credential = ScribeCredential()
  var onSave: (String, String) -> Void = { _, _ in }
  var onReload: () -> Void = {}
  var onToggleLogin: () -> Void = {}
  var onShortcutRecordingChange: (Bool) -> Void = { _ in }
  var onIconThemeChange: (StatusIconTheme) -> Void = { _ in }
  /// Runs after the hold-to-talk shortcut changes (re-register it).
  var onHoldHotkeyChange: () -> Void = {}
  var onPasteLastHotkeyChange: () -> Void = {}
  /// Runs after a While-recording preference changes (e.g. hide the HUD).
  var onWhileRecordingChange: () -> Void = {}
  /// Each runs when anything the Microphone row shows changes.
  private var microphoneObservers: [() -> Void] = []
  /// Each runs only when the choice or the connected inputs change (the
  /// recorder), never for its own fallback report, so they can't loop.
  private var microphoneChoiceObservers: [() -> Void] = []
  var onOpenLog: () -> Void = { NSWorkspace.shared.open(Log.fileURL) }
  var onOpenConfig: () -> Void = {}
  /// Shows the window's Vocabulary tab.
  var onManageVocabulary: () -> Void = {}
  var onLoadVocabulary: () throws -> VocabularySnapshot = { throw SettingsModel.NotReady() }
  var onSaveVocabulary: (VocabularySnapshot) throws -> VocabularySnapshot = { _ in throw SettingsModel.NotReady() }
  /// The vocabulary isn't wired up yet (the app is still starting).
  struct NotReady: Error, LocalizedError {
    var errorDescription: String? { "Khuluma is still starting." }
  }

  /// The configured `audio.sounds` section, refreshed when a config is
  /// adopted — never read from disk on the render path.
  @Published private(set) var configuredSounds = AppSettings.Sounds()
  /// How `configuredSounds` is obtained (the store, once per adopt).
  var soundsProvider: () -> AppSettings.Sounds = { AppSettings.Sounds() }
  func refreshConfiguredSounds() { configuredSounds = soundsProvider() }
  /// `~` and `$SOUNDS_DIR` expansion, as the sound resolver applies it.
  var expandSoundPath: (String) -> String = { $0 }
  /// Sets an event's path and enabled in one write (wired in AppController).
  var onSaveSound: (_ event: String, _ path: String, _ enabled: Bool) -> Void = { _, _, _ in }
  /// Writes the whole per-app send list in one write.
  var onSaveAppRules: ([AppSettings.AppRule]) -> Void = { _ in }
  /// The per-app send rules, from the resolved config.
  var appRules: [AppSettings.AppRule] { config?.inline.appRules ?? [] }
  func saveAppRules(_ rules: [AppSettings.AppRule]) {
    guard editable else { return }
    saving = true
    message = nil
    failed = false
    onSaveAppRules(rules)
  }
  /// Where the user's own sound files live (`<support>/sounds`).
  var soundsDirectory: URL { SoundLibrary.standard.directory }
  /// Plays a row's selected sound once, independent of the master switch.
  let soundPreview = SoundPreview()
  /// The configured sound for an event, as the page needs it.
  func configuredSound(_ event: String) -> AppSettings.Sound { configuredSounds.sound(event) }
  func saveSound(event: String, path: String, enabled: Bool) {
    guard editable else { return }
    saving = true
    message = nil
    failed = false
    onSaveSound(event, path, enabled)
  }
  var onValidateVocabulary: (Data) throws -> VocabularySheet = { try VocabularySheet.decode($0) }
  var onLoadRecentDictations: () throws -> [String] = { [] }
  var preview = false

  private let defaults: UserDefaults
  private let isolated: Bool
  private static let iconThemeKey = "statusIconTheme"
  private static let pasteOnlyModifierKey = "pasteOnlyModifier"
  private static let menuFiguresKey = "menuFigures"
  private static let menuShowsWeekKey = "menuShowsWeek"
  private static let microphoneUIDKey = "microphoneUID"
  private static let microphoneNameKey = "microphoneName"
  private static let holdHotkeyKey = "holdHotkey"
  private static let pasteLastHotkeyKey = "pasteLastHotkey"
  private static let muteWhileRecordingKey = "muteWhileRecording"
  private static let keepAwakeWhileRecordingKey = "keepAwakeWhileRecording"
  private static let showRecordingHUDKey = "showRecordingHUD"
  private static let liveTranscriptionKey = "liveTranscription"

  init(defaults: UserDefaults = AppRuntimePaths.defaults, isolated: Bool = AppRuntimePaths.isolated) {
    self.defaults = defaults
    self.isolated = isolated
    iconTheme = StatusIconTheme(storedValue: defaults.string(forKey: Self.iconThemeKey))
    pasteOnlyModifier = PasteOnlyModifier(storedValue: defaults.string(forKey: Self.pasteOnlyModifierKey))
    menuFigures = MenuFigures(storedValue: defaults.string(forKey: Self.menuFiguresKey))
    menuShowsWeek = defaults.object(forKey: Self.menuShowsWeekKey) as? Bool ?? true
    holdHotkey = defaults.string(forKey: Self.holdHotkeyKey) ?? ""
    pasteLastHotkey = defaults.string(forKey: Self.pasteLastHotkeyKey) ?? ""
    muteWhileRecording = defaults.bool(forKey: Self.muteWhileRecordingKey)
    keepAwakeWhileRecording = defaults.bool(forKey: Self.keepAwakeWhileRecordingKey)
    showRecordingHUD = defaults.bool(forKey: Self.showRecordingHUDKey)
    liveTranscription = defaults.bool(forKey: Self.liveTranscriptionKey)
    microphone = defaults.string(forKey: Self.microphoneUIDKey).map {
      AudioInput(uid: $0, name: defaults.string(forKey: Self.microphoneNameKey) ?? "Chosen microphone")
    }
  }

  var editable: Bool { config != nil && !saving && !recording }
  var provider: String { config?.transcription.provider ?? "parakeet" }
  func adopt(_ config: AppConfig) {
    if self.config?.transcription.provider != config.transcription.provider { keyDraft = "" }
    self.config = config
    refreshConfiguredSounds()
    refreshKeySource()
  }

  /// Presence and place only; the key is not kept.
  func refreshKeySource() {
    guard !preview else { return }
    let credential = self.credential
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let source = credential.source
      DispatchQueue.main.async { self?.keySource = source }
    }
  }

  func saveKey() {
    guard !preview else { return }
    let typed = keyDraft
    keyDraft = ""  // cleared whether or not the save works
    do {
      try credential.save(typed)
      refreshKeySource()
      onReload()
    } catch {
      finished(error: error.localizedDescription)
    }
  }

  func removeKey() {
    guard !preview else { return }
    do {
      try credential.removeStored()
      refreshKeySource()
      onReload()
    } catch {
      finished(error: error.localizedDescription)
    }
  }

  func selectIconTheme(_ theme: StatusIconTheme) {
    guard iconTheme != theme else { return }
    iconTheme = theme
    // Snapshot previews must not write to the daily app's preferences.
    if !preview || isolated { defaults.set(theme.rawValue, forKey: Self.iconThemeKey) }
    onIconThemeChange(theme)
  }

  /// Read when each take starts, so a change applies from the next take.
  /// The paste-only combination (toggle + modifier) is derived, so refuse a
  /// change whose combo would collide with the paste-last shortcut.
  func selectPasteOnlyModifier(_ modifier: PasteOnlyModifier) {
    if let toggle = try? HotkeySpec.parse(config?.hotkey ?? ""),
       let combo = modifier.stopShortcut(for: toggle),
       let last = try? HotkeySpec.parse(pasteLastHotkey), combo == last {
      message = "\(combo.display) is your paste-last-dictation shortcut; clear it or choose another modifier"
      failed = true
      return
    }
    pasteOnlyModifier = modifier
    failed = false
    message = nil
    if !preview || isolated { defaults.set(modifier.rawValue, forKey: Self.pasteOnlyModifierKey) }
  }

  func selectMenuFigures(_ figures: MenuFigures) {
    menuFigures = figures
    if !preview || isolated { defaults.set(figures.rawValue, forKey: Self.menuFiguresKey) }
  }

  func setMenuShowsWeek(_ shows: Bool) {
    menuShowsWeek = shows
    if !preview || isolated { defaults.set(shows, forKey: Self.menuShowsWeekKey) }
  }

  var microphoneChoice: MicrophoneChoice {
    MicrophoneChoice(stored: microphone, inputs: audioInputs, unusableUID: unusableMicrophoneUID)
  }

  func observeMicrophone(_ observer: @escaping () -> Void) { microphoneObservers.append(observer) }
  func observeMicrophoneChoice(_ observer: @escaping () -> Void) { microphoneChoiceObservers.append(observer) }

  /// From the recorder: the chosen device failed (its UID) or works again (nil).
  func reportMicrophoneFallback(_ uid: String?) {
    guard unusableMicrophoneUID != uid else { return }
    unusableMicrophoneUID = uid
    microphoneObservers.forEach { $0() }
  }

  private func microphoneChanged() {
    microphoneChoiceObservers.forEach { $0() }
    microphoneObservers.forEach { $0() }
  }

  /// Nil chooses System Default. Applies from the next take, never mid-take.
  func selectMicrophone(_ input: AudioInput?) {
    // Choosing the same device again retries one that failed.
    guard microphone != input || (input != nil && input?.uid == unusableMicrophoneUID) else { return }
    microphone = input
    if !preview || isolated {
      if let input {
        defaults.set(input.uid, forKey: Self.microphoneUIDKey)
        defaults.set(input.name, forKey: Self.microphoneNameKey)
      } else {
        defaults.removeObject(forKey: Self.microphoneUIDKey)
        defaults.removeObject(forKey: Self.microphoneNameKey)
      }
    }
    microphoneChanged()
  }

  /// Picks by UID from the options shown (connected or the stored one).
  func selectMicrophone(uid: String?) {
    guard let uid else { selectMicrophone(nil); return }
    if let input = audioInputs.devices.first(where: { $0.uid == uid }) ?? (microphone?.uid == uid ? microphone : nil) {
      selectMicrophone(input)
    }
  }

  func adoptAudioInputs(_ inputs: AudioInputs) {
    guard audioInputs != inputs else { return }
    audioInputs = inputs
    // Keep the stored name current while the device is connected.
    if let microphone, let connected = inputs.devices.first(where: { $0.uid == microphone.uid }),
       connected.name != microphone.name {
      self.microphone = connected
      if !preview || isolated { defaults.set(connected.name, forKey: Self.microphoneNameKey) }
    }
    microphoneChanged()
  }

  /// The paste-only shortcut for the current hotkey, if it can be bound.
  var pasteOnlyShortcut: HotkeySpec? {
    (try? HotkeySpec.parse(config?.hotkey ?? "")).flatMap { pasteOnlyModifier.stopShortcut(for: $0) }
  }

  /// "" turns hold-to-talk off. A shortcut that can't be used keeps the old
  /// one and says why in the footer.
  func setHoldHotkey(_ text: String) {
    if !text.isEmpty, let new = try? HotkeySpec.parse(text),
       let last = try? HotkeySpec.parse(pasteLastHotkey), new == last {
      message = "\(last.display) is your paste-last-dictation shortcut; clear it or choose another"
      failed = true
      return
    }
    switch HoldPolicy.hotkey(text, toggle: try? HotkeySpec.parse(config?.hotkey ?? ""), pasteOnly: pasteOnlyShortcut) {
    case .refused(let reason):
      message = reason
      failed = true
    case .ok:
      holdHotkey = text
      failed = false
      message = nil
      if !preview || isolated { defaults.set(text, forKey: Self.holdHotkeyKey) }
      onHoldHotkeyChange()
    }
  }

  /// "" turns the re-paste shortcut off. It can't take over the toggle,
  /// hold-to-talk, paste-only or cancel shortcuts.
  func setPasteLastHotkey(_ text: String) {
    if !text.isEmpty, let new = try? HotkeySpec.parse(text) {
      let clashes: [(HotkeySpec?, String)] = [
        (try? HotkeySpec.parse(config?.hotkey ?? ""), "dictation"),
        (try? HotkeySpec.parse(holdHotkey), "hold-to-talk"),
        (pasteOnlyShortcut, "paste-without-sending"),
        (try? HotkeySpec.parse("ctrl+escape"), "cancel"),
      ]
      for (other, what) in clashes where other == new {
        message = "\(new.display) is your \(what) shortcut; clear it or choose another"
        failed = true
        return
      }
    }
    pasteLastHotkey = text
    failed = false
    message = nil
    if !preview || isolated { defaults.set(text, forKey: Self.pasteLastHotkeyKey) }
    onPasteLastHotkeyChange()
  }

  /// Read when each take starts, so a change applies from the next take.
  func setMuteWhileRecording(_ on: Bool) {
    muteWhileRecording = on
    if !preview || isolated { defaults.set(on, forKey: Self.muteWhileRecordingKey) }
  }

  func setKeepAwakeWhileRecording(_ on: Bool) {
    keepAwakeWhileRecording = on
    if !preview || isolated { defaults.set(on, forKey: Self.keepAwakeWhileRecordingKey) }
  }

  func setShowRecordingHUD(_ on: Bool) {
    showRecordingHUD = on
    if !preview || isolated { defaults.set(on, forKey: Self.showRecordingHUDKey) }
    onWhileRecordingChange()
  }

  /// Read when each take starts, so a change applies from the next take.
  func setLiveTranscription(_ on: Bool) {
    liveTranscription = on
    if !preview || isolated { defaults.set(on, forKey: Self.liveTranscriptionKey) }
  }

  func save(_ key: String, _ value: String) {
    guard editable else { return }
    saving = true
    message = nil
    failed = false
    onSave(key, value)
  }

  func finished(error: String? = nil) {
    saving = false
    failed = error != nil
    message = error ?? "Settings saved"
  }
}
