import Foundation
import Testing
@testable import KhulumaCore

/// settings.json: resolution against golden AppConfig fixtures, fallback,
/// validation, unknown and retired keys.
@Suite struct SettingsTests {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let fixtures = repoRoot.appendingPathComponent("tests/fixtures/settings")

  /// A temp root: user sounds, a bundled-sounds folder and a custom model.
  struct Root {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-settings-\(UUID().uuidString)")
      let fm = FileManager.default
      for dir in ["config", "bundled", "sounds", "models/parakeet-custom-v2", "app"] {
        try fm.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
      }
      for file in ["sounds/start.wav", "sounds/process.wav", "bundled/error.wav"] {
        try Data().write(to: url.appendingPathComponent(file))
      }
    }
    var path: String { url.path }

    /// The app folder is `config/`; the bundled sounds are `bundled/`.
    func environment() -> SettingsEnvironment {
      SettingsEnvironment(appFolder: url.appendingPathComponent("config"), home: path + "/home",
                          bundledSoundsDir: path + "/bundled",
                          defaultSocketPath: path + "/config/khulumad.sock",
                          processingDir: "/tmp/khuluma-processing", keyAvailable: false)
    }

    /// A fixture's expected AppConfig, at this root.
    func expected(_ name: String) throws -> AppConfig {
      let text = try String(contentsOf: SettingsTests.fixtures.appendingPathComponent("\(name).app-config.json"), encoding: .utf8)
      return try JSONDecoder().decode(AppConfig.self, from: Data(text.replacingOccurrences(of: "@ROOT@", with: path).utf8))
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
  }

  func settings(_ name: String, root: Root) throws -> AppSettings {
    let text = try String(contentsOf: Self.fixtures.appendingPathComponent("\(name)/settings.json"), encoding: .utf8)
    return try SettingsStore.decode(Data(text.replacingOccurrences(of: "@ROOT@", with: root.path).utf8))
  }

  @Test func defaultsEqualEmptyConfig() throws {
    let root = try Root(); defer { root.cleanup() }
    let expected = try root.expected("defaults")
    let config = AppConfig(settings: AppSettings(), environment: root.environment())
    #expect(config == expected)
    // And a settings.json with nothing but the schema version reads as the defaults.
    #expect(try SettingsStore.decode(Data(#"{"schema_version":1}"#.utf8)) == AppSettings())
  }

  @Test(arguments: ["full", "cloud"])
  func settingsResolveToTheGoldenConfig(_ name: String) throws {
    let root = try Root(); defer { root.cleanup() }
    let expected = try root.expected(name)
    let settings = try settings(name, root: root)
    let config = AppConfig(settings: settings, environment: root.environment())
    #expect(config == expected)
    // Round trip through settings.json keeps it.
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    try store.save(settings)
    #expect(store.load().settings == settings)
  }

  @Test func invalidFileFallsBackToLastGoodThenDefaults() throws {
    let root = try Root(); defer { root.cleanup() }
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    #expect(store.load().status == .init(error: nil, source: "file"))
    try store.set("inline.autosend", value: "false")
    var loaded = store.load()
    #expect(loaded.settings.inline.autosend == false)
    #expect(FileManager.default.fileExists(atPath: store.lastGoodURL.path))

    try Data("{ half".utf8).write(to: store.url)
    loaded = store.load()
    #expect(loaded.status.source == "last_good" && loaded.status.error != nil)
    #expect(loaded.settings.inline.autosend == false)
    #expect(throws: SettingsStore.InvalidSetting.self) { try store.set("inline.autosend", value: "true") }

    try FileManager.default.removeItem(at: store.lastGoodURL)
    try Data(#"{"schema_version":1,"cleanup":{"repeats_level":9}}"#.utf8).write(to: store.url)
    loaded = store.load()
    #expect(loaded.status.source == "defaults")
    let config = AppConfig(settings: loaded.settings, status: loaded.status, environment: root.environment())
    #expect(config.usingFallbackDefaults)
    #expect(config.inline.autosend == false && config.delivery.autosend == false)
  }

  @Test func setValidation() throws {
    let root = try Root(); defer { root.cleanup() }
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    let good: [(String, String)] = [
      ("transcription.provider", "elevenlabs"), ("transcription.language", "auto"), ("transcription.language", "deu"),
      ("swift_parakeet.model_version", ""), ("swift_parakeet.model_version", "v2"),
      ("swift_parakeet.model_path", root.path + "/models/parakeet-custom-v2"), ("swift_parakeet.model_path", ""),
      ("debug.keep_logs", "1"), ("inline.autosend", "false"), ("audio.sounds.enabled", "0"), ("clean.enabled", "true"),
      ("clean.repeats_level", "3"), ("clean.repeats_level", "5"), ("app.hotkey", "ctrl+option+space"), ("app.hotkey", "F20"), ("app.hotkey", "⌘+⇧+k"),
    ]
    for (key, value) in good { #expect(throws: Never.self) { try store.set(key, value: value) } }
    let bad: [(String, String)] = [
      ("transcription.provider", "whisper"), ("transcription.language", "EN"), ("transcription.language", "english"),
      ("swift_parakeet.model_version", "v4"), ("swift_parakeet.model_path", root.path + "/nope"),
      ("swift_parakeet.model_path", "a\nb"), ("debug.keep_logs", "yes"), ("clean.repeats_level", "6"),
      ("clean.repeats_level", "01"), ("app.hotkey", "space"), ("app.hotkey", "F21"), ("app.hotkey", "ctrl+a+b"),
      ("app.hotkey", "hyper+a"), ("inline.send_mode", "enter"), ("history.retention_days", "-1"), ("history.audio_retention_days", "x"),
    ]
    for (key, value) in bad {
      #expect(throws: SettingsStore.InvalidSetting.self, "\(key)=\(value)") { try store.set(key, value: value) }
    }
    let s = store.load().settings
    #expect(s.transcription.provider == "elevenlabs" && s.hotkey == "⌘+⇧+k" && s.cleanup.repeatsLevel == 5)
  }

  @Test func unknownKeysSurviveWrites() throws {
    let root = try Root(); defer { root.cleanup() }
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    try DataFiles.ensureDirectory(store.folder)
    try Data(#"{"schema_version":1,"agent_note":"hi","inline":{"autosend":true,"future":[1,2]}}"#.utf8).write(to: store.url)
    try store.set("inline.autosend", value: "false")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
    #expect(object["agent_note"] as? String == "hi")
    let inline = object["inline"] as! [String: Any]
    #expect(inline["future"] as? [Int] == [1, 2])
    #expect(inline["autosend"] as? Bool == false)
  }

  @Test func unreadableSettingsAreNeverOverwritten() throws {
    let root = try Root(); defer { root.cleanup() }
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    // A directory where the file should be: a read error, not "missing".
    try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
    #expect(store.load().status.error != nil)
    #expect(throws: SettingsStore.InvalidSetting.self) { try store.set("inline.autosend", value: "false") }
    var dir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: store.url.path, isDirectory: &dir) && dir.boolValue)
  }


  @Test func retiredKeysStillLoadAndGoOnTheNextWrite() throws {
    let root = try Root(); defer { root.cleanup() }
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    try DataFiles.ensureDirectory(store.folder)
    try Data(#"{"schema_version":1,"import_warning":"old","transcription":{"socket_path":"/old.sock","language":"fr"}}"#.utf8)
      .write(to: store.url)
    let loaded = store.load()
    #expect(loaded.status == .init(error: nil, source: "file"))
    #expect(loaded.settings.transcription.language == "fr")
    try store.set("inline.autosend", value: "false")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
    #expect(object["import_warning"] == nil)
    let transcription = object["transcription"] as! [String: Any]
    #expect(transcription["socket_path"] == nil && transcription["language"] as? String == "fr")
  }

  @Test func soundsResolveToTheConfiguredFileElseTheBundledDefault() throws {
    let root = try Root(); defer { root.cleanup() }
    var settings = AppSettings()
    settings.sounds.events["start"] = .init(enabled: true, path: root.path + "/sounds/start.wav")
    settings.sounds.events["stop"] = .init(enabled: true, path: "~/gone.wav")
    let config = AppConfig(settings: settings, environment: root.environment())
    #expect(config.sounds["start"]?.path == root.path + "/sounds/start.wav")
    #expect(config.sounds["stop"]?.path == nil && config.sounds["stop"]?.enabled == false)
    #expect(config.sounds["error"]?.path == root.path + "/bundled/error.wav")
    #expect(config.sounds["process"]?.path == nil)
  }
}
