import AppKit
import KhulumaCore

/// Dictation settings come from the CLI; app presentation uses private defaults.
final class SettingsModel: ObservableObject {
  @Published private(set) var config: AppConfig?
  @Published private(set) var iconTheme: StatusIconTheme
  @Published var saving = false
  @Published var recording = false
  @Published var message: String?
  @Published var failed = false
  @Published var loginStatus = LoginItem.status
  var onSave: (String, String) -> Void = { _, _ in }
  var onReload: () -> Void = {}
  var onToggleLogin: () -> Void = {}
  var onShortcutRecordingChange: (Bool) -> Void = { _ in }
  var onIconThemeChange: (StatusIconTheme) -> Void = { _ in }
  var onOpenLog: () -> Void = { NSWorkspace.shared.open(Log.fileURL) }
  var onOpenConfig: () -> Void = {}
  var preview = false

  private let defaults: UserDefaults
  private let isolated: Bool
  private static let iconThemeKey = "statusIconTheme"

  init(defaults: UserDefaults = AppRuntimePaths.defaults, isolated: Bool = AppRuntimePaths.isolated) {
    self.defaults = defaults
    self.isolated = isolated
    iconTheme = StatusIconTheme(storedValue: defaults.string(forKey: Self.iconThemeKey))
  }

  var editable: Bool { config != nil && !saving && !recording }
  var provider: String { config?.transcription.provider ?? "parakeet" }
  func adopt(_ config: AppConfig) { self.config = config }

  func selectIconTheme(_ theme: StatusIconTheme) {
    guard iconTheme != theme else { return }
    iconTheme = theme
    // Snapshot previews must not write to the daily app's preferences.
    if !preview || isolated { defaults.set(theme.rawValue, forKey: Self.iconThemeKey) }
    onIconThemeChange(theme)
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
