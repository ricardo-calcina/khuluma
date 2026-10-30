import AppKit
import KhulumaCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    Form {
      Section {
        LabeledContent("Shortcut") {
          ShortcutRecorder(value: model.config?.hotkey ?? "", isEnabled: model.editable,
                           onCapture: { model.save("app.hotkey", $0) },
                           onRecordingChange: model.onShortcutRecordingChange)
            .fixedSize()
        }
        .help("Click to record a shortcut. Press it once to start dictation, then again to finish. Control–Escape cancels dictation.")
        Toggle("Auto-send", isOn: setting("inline.autosend", model.config?.inline.autosend ?? false))
          .disabled(!model.editable)
          .help("Paste the transcript, then send it with your configured send key.")
        Picker("Paste without sending", selection: Binding(get: { model.pasteOnlyModifier },
                                                           set: model.selectPasteOnlyModifier)) {
          ForEach(PasteOnlyModifier.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .disabled(model.config?.inline.autosend != true)
        .help("Hold this key with your shortcut when you finish a take to paste it without sending.")
        if model.config?.inline.autosend == true, model.pasteOnlyModifier != .off {
          Text(pasteOnlyNote).font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Sounds", isOn: setting("audio.sounds.enabled", model.config?.soundsEnabled ?? true))
          .disabled(!model.editable)
          .help("Play sounds during dictation.")
      } header: { Text("Dictation") }

      Section {
        Toggle("Clean up dictation", isOn: setting("clean.enabled", model.config?.cleanup.clean == "1"))
          .disabled(!model.editable)
        Picker("Repetition", selection: Binding(
          get: { model.config?.cleanup.repeatsLevel ?? "0" },
          set: { model.save("clean.repeats_level", $0) })) {
          Text("Keep repetitions").tag("0")
          Text("Repeated words").tag("1")
          Text("Words and short phrases").tag("2")
          Text("Exact repeated sentences").tag("3")
        }
        .disabled(!model.editable || model.config?.cleanup.clean != "1")
        Text("Removes the fillers in your vocabulary. Sentence cleanup keeps changed wording and short emphasis.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Manage Vocabulary…") { model.showingVocabulary = true }
          .disabled(!model.editable)
        Text("One vocabulary for fillers, brands and other words. Edit entries here, or import and export JSON.")
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text("Cleanup & vocabulary") }

      Section {
        Picker("Model", selection: Binding(get: { model.provider }, set: { model.save("transcription.provider", $0) })) {
          Text(localModelTitle).tag("parakeet")
          Text("ElevenLabs Scribe v2").tag("elevenlabs")
        }
        .disabled(!model.editable)
        if model.provider == "elevenlabs" {
          LabeledContent("API key") {
            Label(model.config?.transcription.keyAvailable == true ? "Available" : "Missing",
                  systemImage: model.config?.transcription.keyAvailable == true ? "checkmark.circle" : "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
          if model.config?.transcription.keyAvailable != true {
            Text("Export ELEVENLABS_API_KEY in your shell, then click Reload Settings below.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("Scribe uploads new and recovered recordings to ElevenLabs and uses your credits. Internet required.")
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text("Transcription") }

      Section {
        Picker("Menu bar icons", selection: Binding(get: { model.iconTheme }, set: model.selectIconTheme)) {
          ForEach(StatusIconTheme.allCases, id: \.self) { theme in
            Text(theme.title).tag(theme)
          }
        }
        .help("Changes immediately, including during dictation.")
        Text("Both use the same Ready emblem. Full emblem keeps the symbol visible while recording and processing.")
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text("Appearance") }

      Section {
        Toggle("Start at login", isOn: Binding(
          get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
          set: { _ in model.onToggleLogin(); model.loginStatus = LoginItem.status }))
          .disabled(AppRuntimePaths.isolated || model.preview)
        if model.loginStatus == .requiresApproval {
          Button("Approve in System Settings") { model.onToggleLogin() }
        }
      } header: { Text("Startup") }

      Section {
        Toggle("Diagnostic logging", isOn: setting("debug.keep_logs", model.config?.transcription.keepLogs ?? false))
          .disabled(!model.editable)
        Text("Keeps recording audio and debug files. Audio follows your history retention settings.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Open Log") { model.onOpenLog() }
            .help("Open Khuluma’s diagnostic log. Usage stats contain counts and durations, never dictated text.")
          Button("Open Config") { model.onOpenConfig() }.disabled(model.config == nil)
            .help("Open the configuration file for advanced settings.")
          Spacer()
          Button("Reload Settings") { model.onReload() }.disabled(model.saving)
            .help("Read changes to your configuration and shell environment.")
        }
      } header: { Text("Diagnostics") }

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
    .formStyle(.grouped)
    .sheet(isPresented: $model.showingVocabulary) { VocabularyView(settings: model) }
  }

  private var localModelTitle: String {
    "Parakeet \(model.config?.transcription.modelVersion ?? "v3") · On this Mac"
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
