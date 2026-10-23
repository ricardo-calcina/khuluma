import AppKit
import KhulumaCore

/// Settings always come back from the CLI's authoritative config reader.
final class SettingsModel: ObservableObject {
  @Published private(set) var config: AppConfig?
  @Published var saving = false
  @Published var recording = false
  @Published var message: String?
  @Published var failed = false
  @Published var loginStatus = LoginItem.status
  var onSave: (String, String) -> Void = { _, _ in }
  var onReload: () -> Void = {}
  var onToggleLogin: () -> Void = {}
  var onShortcutRecordingChange: (Bool) -> Void = { _ in }
  var onOpenLog: () -> Void = { NSWorkspace.shared.open(Log.fileURL) }
  var onOpenConfig: () -> Void = {}
  var preview = false

  var editable: Bool { config != nil && !saving && !recording }
  var provider: String { config?.transcription.provider ?? "parakeet" }
  var modelTitle: String {
    guard let config else { return "Loading model…" }
    if provider == "elevenlabs" { return "Scribe v2" }
    if provider != "parakeet" { return "Unknown model" }
    let version = config.transcription.modelVersion ?? "v3"
    return "Parakeet \(version)"
  }
  var hotkeyTitle: String {
    guard let value = config?.hotkey else { return "–" }
    return (try? HotkeySpec.parse(value).display) ?? value
  }

  func adopt(_ config: AppConfig) { self.config = config }

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
