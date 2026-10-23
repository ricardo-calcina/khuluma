import AppKit
import KhulumaCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    Form {
      Section {
        LabeledContent("Dictation shortcut") {
          ShortcutRecorder(value: model.config?.hotkey ?? "", isEnabled: model.editable,
                           onCapture: { model.save("app.hotkey", $0) },
                           onRecordingChange: model.onShortcutRecordingChange)
        }
        Text("Press once to start, then again to finish. Control–Escape cancels a recording.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Paste and send automatically", isOn: setting("inline.autosend", model.config?.inline.autosend ?? false))
          .disabled(!model.editable)
        Toggle("Play dictation sounds", isOn: setting("audio.sounds.enabled", model.config?.soundsEnabled ?? true))
          .disabled(!model.editable)
      } header: { Text("Dictation") }

      Section {
        Picker("Transcription model", selection: Binding(get: { model.provider }, set: { model.save("transcription.provider", $0) })) {
          Text(localModelTitle).tag("parakeet")
          Text("ElevenLabs Scribe v2 · Cloud").tag("elevenlabs")
        }
        .disabled(!model.editable)
        if model.provider == "elevenlabs" {
          Label(model.config?.transcription.keyAvailable == true ? "API key found" : "API key not found", systemImage: "key")
            .font(.callout)
          if model.config?.transcription.keyAvailable != true {
            Text("Export ELEVENLABS_API_KEY in your shell settings, then choose Reload Settings.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Label("Transcribed on this Mac", systemImage: "desktopcomputer")
            .font(.callout).foregroundStyle(.secondary)
        }
        Text("Parakeet works on this Mac. Choosing Scribe sends new and recovered recordings to ElevenLabs and uses your credits. Scribe needs an internet connection.")
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text("Model") }

      Section {
        Toggle("Start at Login", isOn: Binding(
          get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
          set: { _ in model.onToggleLogin(); model.loginStatus = LoginItem.status }))
          .disabled(AppRuntimePaths.isolated || model.preview)
        if model.loginStatus == .requiresApproval {
          Button("Approve in System Settings") { model.onToggleLogin() }
        }
      } header: { Text("Startup") }

      Section {
        Toggle("Keep diagnostic files", isOn: setting("debug.keep_logs", model.config?.transcription.keepLogs ?? false))
          .disabled(!model.editable)
        Text("Keeps recording audio and debug files for troubleshooting. Audio follows your history retention settings.")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Open Log") { model.onOpenLog() }
          Button("Open Config") { model.onOpenConfig() }.disabled(model.config == nil)
          Spacer()
          Button("Reload Settings") { model.onReload() }.disabled(model.saving)
        }
        Text("Usage stats contain counts and durations, never your dictated text.")
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text("Diagnostics") }

      if model.recording {
        Label("Finish dictating and let processing complete before changing settings.", systemImage: "mic.fill")
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
  }

  private var localModelTitle: String {
    "Parakeet \(model.config?.transcription.modelVersion ?? "v3") · On this Mac"
  }

  private func setting(_ key: String, _ value: Bool) -> Binding<Bool> {
    Binding(get: { value }, set: { model.save(key, $0 ? "true" : "false") })
  }

}
