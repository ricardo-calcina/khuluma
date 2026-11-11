import AppKit
import KhulumaCore
import SwiftUI

/// The Settings tab's pages, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable {
  case general, recording, transcription, text, cloud, advanced
  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .recording: "Recording"
    case .transcription: "Transcription"
    case .text: "Text"
    case .cloud: "Cloud"
    case .advanced: "Advanced"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .recording: "mic"
    case .transcription: "waveform"
    case .text: "text.alignleft"
    case .cloud: "cloud"
    case .advanced: "wrench.and.screwdriver"
    }
  }
}

struct SettingsView: View {
  @ObservedObject var model: SettingsModel
  @FocusState private var focusedPage: SettingsPage?

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle().fill(Ink.rule).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(model.page.title)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
          page
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }
    .toggleStyle(.switch)
    .tint(Ember.accent)
    .background(Surface.canvas)
  }

  // MARK: Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(SettingsPage.allCases) { page in
        SidebarRow(page: page, selected: model.page == page, focused: focusedPage == page) { select(page) }
          .focusable()
          .focusEffectDisabled()
          .focused($focusedPage, equals: page)
          .onKeyPress(.space) { select(page); return .handled }
          .onMoveCommand { move($0) }
      }
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 18)
    // Wide enough for "Transcription" on one line.
    .frame(width: 165)
  }

  private func select(_ page: SettingsPage) {
    model.page = page
    focusedPage = page
  }

  /// Up/Down move selection and focus together.
  private func move(_ direction: MoveCommandDirection) {
    let pages = SettingsPage.allCases
    guard let index = pages.firstIndex(of: model.page) else { return }
    switch direction {
    case .up where index > 0: select(pages[index - 1])
    case .down where index < pages.count - 1: select(pages[index + 1])
    default: break
    }
  }

  @ViewBuilder private var page: some View {
    switch model.page {
    case .general: general
    case .recording: recording
    case .transcription: transcription
    case .text: text
    case .cloud: cloud
    case .advanced: advanced
    }
  }

  // MARK: Pages

  @ViewBuilder private var general: some View {
    SettingsGroup("Startup") {
      SettingsRow("Start at login") {
        Toggle("Start at login", isOn: Binding(
          get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
          set: { _ in model.onToggleLogin(); model.loginStatus = LoginItem.status }))
          .labelsHidden()
          .disabled(AppRuntimePaths.isolated || model.preview)
      }
      if model.loginStatus == .requiresApproval {
        SettingsRow("Needs approval", note: "macOS asks you to allow Khuluma as a login item.") {
          Button("Approve in System Settings") { model.onToggleLogin() }
        }
      }
    }
    SettingsGroup("Menu bar") {
      SettingsRow("Menu bar icons",
                  note: "Both use the same Ready emblem. Full emblem keeps the symbol visible while recording and processing.") {
        Picker("Menu bar icons", selection: Binding(get: { model.iconTheme }, set: model.selectIconTheme)) {
          ForEach(StatusIconTheme.allCases, id: \.self) { theme in Text(theme.title).tag(theme) }
        }
        .labelsHidden().fixedSize()
        .help("Changes immediately, including during dictation.")
      }
      SettingsRow("Menu figures", note: "Words, time saved and words per minute cover all time or today.") {
        Picker("Menu figures", selection: Binding(get: { model.menuFigures }, set: model.selectMenuFigures)) {
          ForEach(MenuFigures.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
        .help("Words, time saved and words per minute in the menu cover all time or today.")
      }
      SettingsRow("Show last 7 days in menu", last: true) {
        Toggle("Show last 7 days in menu", isOn: Binding(get: { model.menuShowsWeek }, set: model.setMenuShowsWeek))
          .labelsHidden()
      }
    }
  }

  @ViewBuilder private var recording: some View {
    SettingsGroup("Shortcuts") {
      SettingsRow("Shortcut", note: "Press once to start, again to finish. Control–Escape cancels.") {
        ShortcutRecorder(value: model.config?.hotkey ?? "", isEnabled: model.editable,
                         onCapture: { model.save("app.hotkey", $0) },
                         onRecordingChange: model.onShortcutRecordingChange)
          .fixedSize()
      }
      .help("Click to record a shortcut. Press it once to start dictation, then again to finish. Control–Escape cancels dictation.")
      SettingsRow("Hold to talk", note: "Hold to record, release to finish. Off until you set a shortcut.", last: true) {
        HStack(spacing: 8) {
          ShortcutRecorder(value: model.holdHotkey, isEnabled: model.editable,
                           onCapture: { model.setHoldHotkey($0) },
                           onRecordingChange: model.onShortcutRecordingChange)
            .fixedSize()
          if !model.holdHotkey.isEmpty {
            Button("Clear") { model.setHoldHotkey("") }
              .fixedSize()
          }
        }
      }
      .help("A second shortcut: hold it to record, release to finish. A quick tap discards the take.")
    }
    SettingsGroup("Microphone and sounds") {
      microphoneRow
      SettingsRow("Sounds", last: true) {
        Toggle("Sounds", isOn: setting("audio.sounds.enabled", model.config?.soundsEnabled ?? true))
          .labelsHidden()
          .disabled(!model.editable)
          .help("Play sounds during dictation.")
      }
    }
    SettingsGroup("While recording") {
      SettingsRow("Mute other audio", note: "Silences this Mac's sound output while you dictate, after the start sound.") {
        Toggle("Mute other audio", isOn: Binding(get: { model.muteWhileRecording },
                                               set: model.setMuteWhileRecording))
          .labelsHidden()
      }
      SettingsRow("Keep Mac awake", note: "Stops the Mac sleeping during long dictation.") {
        Toggle("Keep Mac awake", isOn: Binding(get: { model.keepAwakeWhileRecording },
                                               set: model.setKeepAwakeWhileRecording))
          .labelsHidden()
      }
      SettingsRow("Show on-screen indicator",
                  note: "A small recording and transcribing marker at the bottom of the screen.", last: true) {
        Toggle("Show on-screen indicator", isOn: Binding(get: { model.showRecordingHUD },
                                                         set: model.setShowRecordingHUD))
          .labelsHidden()
      }
    }
  }

  @ViewBuilder private var transcription: some View {
    SettingsGroup("Model") {
      // Shown before Scribe is chosen too: choosing it saves at once.
      SettingsRow("Dictation model",
                  note: "Scribe uploads new and recovered dictation to ElevenLabs and uses your credits.") {
        Picker("Dictation model", selection: Binding(get: { model.provider }, set: { model.save("transcription.provider", $0) })) {
          Text(localModelTitle).tag("parakeet")
          Text("ElevenLabs Scribe v2").tag("elevenlabs")
        }
        .labelsHidden().fixedSize()
        .disabled(!model.editable)
      }
      if model.provider == "elevenlabs", model.config?.transcription.keyAvailable != true {
        SettingsRow("Scribe needs an ElevenLabs key.") {
          Button("Open Cloud") { model.page = .cloud }
            .fixedSize()
        }
      }
      SettingsRow("Transcribe while recording",
                  note: "Finishes long dictation faster and saves the recording to disk as you speak. Parakeet only.",
                  last: model.provider != "elevenlabs") {
        Toggle("Transcribe while recording", isOn: Binding(get: { model.liveTranscription },
                                                           set: model.setLiveTranscription))
          .labelsHidden()
          .disabled(model.provider == "elevenlabs")
      }
      if model.provider == "elevenlabs" {
        SettingsRow("Language") {
          Picker("Language", selection: Binding(get: { model.config?.transcription.language ?? "en" },
                                                set: { model.save("transcription.language", $0) })) {
            ForEach(languageCodes, id: \.self) { Text(languageTitle($0)).tag($0) }
          }
          .labelsHidden().fixedSize()
          .disabled(!model.editable)
          .help("Auto-detect lets Scribe recognise the language of each recording.")
        }
        SettingsRow("Label sounds", note: "Include labels like (laughter) in Scribe dictation.", last: true) {
          Toggle("Label sounds", isOn: setting("transcription.scribe_tag_audio_events",
                                               model.config?.transcription.scribeTagAudioEvents ?? true))
            .labelsHidden()
            .disabled(!model.editable)
            .help("Include labels for sounds such as laughter in Scribe dictation.")
        }
      }
    }
  }

  @ViewBuilder private var cloud: some View {
    SettingsGroup("ElevenLabs") {
      Text("Audio only leaves this Mac when you choose Scribe or Transcribe with Cloud.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
      let available = model.config?.transcription.keyAvailable == true
      SettingsRow("ElevenLabs key", note: Self.keyStatus(model.keySource, available: available),
                  footnote: "Used for Scribe dictation and Finder's Transcribe with Cloud. Saved keys go in Keychain.",
                  last: true) {
        HStack(spacing: 8) {
          SecureField("API key", text: $model.keyDraft)
            .labelsHidden().frame(width: 110)
            .accessibilityLabel("ElevenLabs API key")
            .onSubmit { model.saveKey() }
          Button("Save") { model.saveKey() }
            .fixedSize()
            .disabled(model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if model.keySource == .keychain {
            Button("Remove") { model.removeKey() }
              .fixedSize()
          }
        }
      }
    }
  }

  private static func keyStatus(_ source: ScribeCredential.Source?, available: Bool) -> String {
    switch source {
    case .keychain?: return "In Keychain"
    case .environment?, .shellSettings?: return "From shell settings"
    case nil: return available ? "Available" : "Missing"
    }
  }

  @ViewBuilder private var text: some View {
    SettingsGroup("Delivery") {
      SettingsRow("Auto-send", note: "Paste the transcript, then send it with your send key.") {
        Toggle("Auto-send", isOn: setting("inline.autosend", model.config?.inline.autosend ?? false))
          .labelsHidden()
          .disabled(!model.editable)
          .help("Paste the transcript, then send it with your configured send key.")
      }
      SettingsRow("Paste without sending",
                  note: model.config?.inline.autosend == true && model.pasteOnlyModifier != .off ? pasteOnlyNote : nil,
                  last: true) {
        Picker("Paste without sending", selection: Binding(get: { model.pasteOnlyModifier },
                                                           set: model.selectPasteOnlyModifier)) {
          ForEach(PasteOnlyModifier.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
        .disabled(model.config?.inline.autosend != true)
        .help("Hold this key with your shortcut when you finish a take to paste it without sending.")
      }
    }
    SettingsGroup("Cleanup") {
      SettingsRow("Clean up dictation",
                  note: "Removes the fillers in your vocabulary. The two options below need this on.") {
        Toggle("Clean up dictation", isOn: setting("clean.enabled", model.config?.cleanup.clean == "1"))
          .labelsHidden()
          .disabled(!model.editable)
      }
      SettingsRow("Repeated sentences",
                  note: "A sentence of five or more words said twice in a row is kept once.") {
        Toggle("Repeated sentences", isOn: Binding(
          get: { RepetitionChoice(level: model.config?.cleanup.repeatsLevel ?? "0").sentences },
          set: { on in
            var choice = RepetitionChoice(level: model.config?.cleanup.repeatsLevel ?? "0")
            choice.sentences = on
            model.save("clean.repeats_level", choice.level)
          }))
          .labelsHidden()
          .disabled(!model.editable || model.config?.cleanup.clean != "1")
      }
      SettingsRow("Repeated words",
                  note: repeatedWordsNote,
                  last: true) {
        Picker("Repeated words", selection: Binding(
          get: { RepetitionChoice(level: model.config?.cleanup.repeatsLevel ?? "0").words },
          set: { words in
            var choice = RepetitionChoice(level: model.config?.cleanup.repeatsLevel ?? "0")
            choice.words = words
            model.save("clean.repeats_level", choice.level)
          })) {
          Text("Keep").tag(RepetitionChoice.Words.keep)
          Text("Single words").tag(RepetitionChoice.Words.words)
          Text("Words and short phrases").tag(RepetitionChoice.Words.phrases)
        }
        .labelsHidden().fixedSize()
        .disabled(!model.editable || model.config?.cleanup.clean != "1")
      }
    }
    SettingsGroup("Vocabulary") {
      Button { model.onManageVocabulary() } label: {
        HStack(spacing: 12) {
          RingMark(symbol: "character.book.closed", size: 22)
          VStack(alignment: .leading, spacing: 2) {
            Text("Manage Vocabulary")
            Text("One vocabulary for fillers, brands, other words and examples, in the Vocabulary tab.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          Image(systemName: "arrow.right").foregroundStyle(Ember.accent).fontWeight(.semibold)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Manage Vocabulary")
    }
  }

  @ViewBuilder private var advanced: some View {
    SettingsGroup("Diagnostics") {
      SettingsRow("Diagnostic logging",
                  note: "Keeps recording audio and debug files. Audio follows your history retention settings.",
                  last: true) {
        Toggle("Diagnostic logging", isOn: setting("debug.keep_logs", model.config?.transcription.keepLogs ?? false))
          .labelsHidden()
          .disabled(!model.editable)
      }
    }
    SettingsGroup("Files") {
      SettingsRow("Log", note: "Usage stats contain counts and durations, never dictated text.") {
        Button("Open Log") { model.onOpenLog() }
          .help("Open Khuluma’s diagnostic log. Usage stats contain counts and durations, never dictated text.")
      }
      SettingsRow("Configuration", note: "The configuration file, for advanced settings.") {
        Button("Open Config") { model.onOpenConfig() }.disabled(model.config == nil)
          .help("Open the configuration file for advanced settings.")
      }
      SettingsRow("Reload", note: "Read changes to your configuration and shell environment.", last: true) {
        Button("Reload Settings") { model.onReload() }.disabled(model.saving)
          .help("Read changes to your configuration and shell environment.")
      }
    }
  }

  /// Recording, save and error feedback: a footer outside the scroll, so it
  /// stays visible in short windows, shown only when there is something to say.
  @ViewBuilder private var footer: some View {
    if model.recording || model.message != nil || model.saving {
      VStack(alignment: .leading, spacing: 0) {
        Rule()
        status.padding(.horizontal, 20).padding(.vertical, 10)
      }
      .background(Surface.canvas)
    }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.recording {
        Label("Dictation controls are available when dictation finishes.", systemImage: "mic.fill")
          .font(.callout)
      }
      if let message = model.message {
        Label(message, systemImage: model.failed ? "exclamationmark.triangle" : "checkmark.circle")
          .font(.callout).foregroundStyle(model.failed ? Color.primary : Color.secondary)
          .accessibilityLabel(message)
      }
      if model.saving { ProgressView("Saving settings…").controlSize(.small) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The same choice as the menu's Microphone row, for when that is hidden.
  private var microphoneRow: some View {
    let choice = model.microphoneChoice
    return SettingsRow("Microphone", footnote: choice.note) {
      Picker("Microphone", selection: Binding(get: { choice.stored?.uid ?? "" },
                                              set: { model.selectMicrophone(uid: $0.isEmpty ? nil : $0) })) {
        ForEach(Array(choice.options.enumerated()), id: \.offset) { index, option in
          Text(option.detail.map { "\(option.title) (\($0))" } ?? option.title)
            .tag(option.uid ?? "")
            .disabled(!option.connected)
          if index == 0, choice.options.count > 1 { Divider() }
        }
      }
      .labelsHidden()
      .frame(maxWidth: 250)
      .help("Takes record from this input. A change applies from the next take.")
    }
  }

  private var localModelTitle: String {
    "Parakeet \(model.config?.transcription.modelVersion ?? "v3") · On this Mac"
  }

  /// Auto-detect, common Scribe languages, and any other code set in config.
  private var languageCodes: [String] {
    let common = ["auto", "en", "es", "fr", "de", "it", "pt", "nl", "zu", "af", "ar", "hi", "ja", "zh"]
    let current = model.config?.transcription.language ?? "en"
    return common.contains(current) ? common : common + [current]
  }

  private func languageTitle(_ code: String) -> String {
    code == "auto" ? "Auto-detect" : Locale.current.localizedString(forLanguageCode: code) ?? code
  }

  /// The note under "Repeated words" follows the current selection.
  private var repeatedWordsNote: String {
    switch RepetitionChoice(level: model.config?.cleanup.repeatsLevel ?? "0").words {
    case .keep:
      "Repeated words are left as you said them."
    case .words:
      "\u{201C}I I think\u{201D} becomes \u{201C}I think\u{201D}. Doubles such as \u{201C}had had\u{201D} are joined too."
    case .phrases:
      "\u{201C}a branded a branded entry\u{201D} becomes \u{201C}a branded entry\u{201D}. Doubles such as \u{201C}had had\u{201D} are joined too."
    }
  }

  private var pasteOnlyNote: String {
    guard let shortcut = model.pasteOnlyShortcut else {
      return "Your shortcut already uses this key, or the combination is reserved. Choose another key."
    }
    return "Finish with \(shortcut.display) to paste without sending."
  }

  private func setting(_ key: String, _ value: Bool) -> Binding<Bool> {
    Binding(get: { value }, set: { model.save(key, $0 ? "true" : "false") })
  }

}

// MARK: Building blocks

/// A sidebar page: ring mark and title, tinted ember when selected.
private struct SidebarRow: View {
  let page: SettingsPage
  let selected: Bool
  var focused = false
  let action: () -> Void
  // Not @State: the Command Line Tools have no SwiftUI macro plugin.
  @StateObject private var hover = Hover()

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        RingMark(symbol: page.symbol, size: 20, tint: selected ? Ember.accent : Ink.color.opacity(0.7))
        Text(page.title)
          .fontWeight(selected ? .semibold : .regular)
          .foregroundStyle(selected ? Ember.accentText : Color.primary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(selected ? Ember.accent.opacity(0.14) : hover.active ? Ink.track : .clear))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
        .strokeBorder(Ember.accent, lineWidth: focused ? 2 : 0))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover.active = $0 }
    .accessibilityLabel(page.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private final class Hover: ObservableObject {
    @Published var active = false
  }
}

/// A group of rows under a small caps label.
private struct SettingsGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Ink.label(title).padding(.bottom, 4)
      content
    }
    .padding(.bottom, 18)
  }
}

/// Title and optional note on the left, the control on the right.
private struct SettingsRow<Control: View>: View {
  let title: String
  var note: String?
  /// A note under the whole row, for text too long beside the control.
  var footnote: String?
  var last = false
  @ViewBuilder let control: Control

  init(_ title: String, note: String? = nil, footnote: String? = nil, last: Bool = false,
       @ViewBuilder control: () -> Control) {
    self.title = title
    self.note = note
    self.footnote = footnote
    self.last = last
    self.control = control()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).fixedSize()
          if let note {
            Text(note).font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        control
      }
      .padding(.vertical, 7)
      if let footnote {
        Text(footnote).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, 7)
      }
      if !last { Rule() }
    }
  }
}
