import Foundation
import Testing
@testable import KhulumaCore

/// settings.json: parity with `khuluma app-config --json` (fixtures from
/// tests/gen-settings-fixtures.sh), fallback, validation, unknown keys, import.
@Suite struct SettingsTests {
  static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let fixtures = repoRoot.appendingPathComponent("tests/fixtures/settings")

  /// A temp root laid out like the generator's.
  struct Root {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-settings-\(UUID().uuidString)")
      let fm = FileManager.default
      for dir in ["config", "data/sounds/khuluma", "sounds", "models/parakeet-custom-v2", "app"] {
        try fm.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
      }
      for file in ["sounds/start.wav", "sounds/process.wav", "data/sounds/khuluma/error.wav"] {
        try Data().write(to: url.appendingPathComponent(file))
      }
    }
    var path: String { url.path }

    /// Resolves against the root the way the generator's CLI run did; the
    /// app folder stands where the CLI's config dir was.
    func environment(ffmpeg: Bool) -> SettingsEnvironment {
      SettingsEnvironment(appFolder: url.appendingPathComponent("config"), home: path + "/home",
                          soundsDir: path + "/data/sounds/khuluma", modelsDir: path + "/data/khuluma/models",
                          defaultSocketPath: path + "/config/.cache/khulumad.sock",
                          processingDir: "/tmp/khuluma-processing", ffmpegAvailable: ffmpeg, keyAvailable: false)
    }

    /// The CLI's output for a fixture, at this root, with the placeholder
    /// version fields a settings-built config carries.
    func expected(_ name: String) throws -> AppConfig {
      var text = try String(contentsOf: SettingsTests.fixtures.appendingPathComponent("\(name).app-config.json"), encoding: .utf8)
      text = text.replacingOccurrences(of: "@ROOT@", with: path)
      var object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
      object["cli_version"] = AppConfig.nativeCLIVersion
      return try AppContract.decodeAppConfig(JSONSerialization.data(withJSONObject: object))
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
  }

  func converted(_ toml: URL, root: Root) throws -> AppSettings {
    let text = try String(contentsOf: toml, encoding: .utf8).replacingOccurrences(of: "@ROOT@", with: root.path)
    return try LegacySettings.convert(Data(text.utf8)).settings
  }

  @Test func defaultsEqualEmptyConfig() throws {
    let root = try Root(); defer { root.cleanup() }
    let expected = try root.expected("defaults")
    let config = AppConfig(settings: AppSettings(), environment: root.environment(ffmpeg: expected.transcription.ffmpeg))
    #expect(config == expected)
    // And a settings.json with nothing but the schema version reads as the defaults.
    #expect(try SettingsStore.decode(Data(#"{"schema_version":1}"#.utf8)) == AppSettings())
  }

  @Test(arguments: ["empty", "cascade", "dictation", "sheet"])
  func cleanupFixtureConfigsMatchCLI(_ name: String) throws {
    let root = try Root(); defer { root.cleanup() }
    let expected = try root.expected("cleanup-" + name)
    let toml = Self.repoRoot.appendingPathComponent("tests/fixtures/cleanup/configs/\(name)/config.toml")
    let settings = try converted(toml, root: root)
    #expect(AppConfig(settings: settings, environment: root.environment(ffmpeg: expected.transcription.ffmpeg)) == expected)
  }

  @Test(arguments: ["full", "cloud"])
  func syntheticConfigsMatchCLI(_ name: String) throws {
    let root = try Root(); defer { root.cleanup() }
    let expected = try root.expected(name)
    let settings = try converted(Self.fixtures.appendingPathComponent("\(name)/config.toml"), root: root)
    let config = AppConfig(settings: settings, environment: root.environment(ffmpeg: expected.transcription.ffmpeg))
    #expect(config == expected)
    // Round trip through settings.json keeps it.
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    try store.save(settings)
    #expect(store.load().settings == settings)
  }

  @Test func fullConfigCarriesKeepListAndSkipsTheRest() throws {
    let root = try Root(); defer { root.cleanup() }
    let text = try String(contentsOf: Self.fixtures.appendingPathComponent("full/config.toml"), encoding: .utf8)
    let conversion = try LegacySettings.convert(Data(text.utf8))
    #expect(conversion.settings.history.typingWpm == 55)
    #expect(conversion.settings.history.retentionDays == 30)
    #expect(conversion.settings.history.audioRetentionDays == 5)
    #expect(conversion.settings.inline.pasteTarget == "restore")
    #expect(conversion.settings.sounds.sound("cancel").enabled == false)
    #expect(conversion.skipped.map(\.key) == ["extra.list", "extra.unused", "meta.config_version"])
  }

  @Test func tomlReader() throws {
    let doc = try TOMLReader.parse("""
      # c
      [a . "b c"]  # header comment
      s = "x\\ty\\u00e9" # c
      l = 'C:\\path'
      n = -1_000
      f = 1.5e2
      t = true
      arr = ["a", 'b',]
      d = 1979-05-27
      it = { x = 1 }
      dotted.key = 1
      """)
    #expect(doc.values[#"a."b c".s"#] == .string("x\tyé"))
    #expect(doc.values[#"a."b c".l"#] == .string("C:\\path"))
    #expect(doc.values[#"a."b c".n"#] == .int(-1000))
    #expect(doc.values[#"a."b c".f"#] == .float(150))
    #expect(doc.values[#"a."b c".t"#] == .bool(true))
    #expect(doc.values[#"a."b c".arr"#] == .strings(["a", "b"]))
    #expect(Set(doc.unreadable.map(\.path)) == [#"a."b c".d"#, #"a."b c".it"#, #"a."b c".dotted.key"#])
    for bad in ["[a", "x = ", "x = \"open", "x = 1 2", "x = 1\nx = 2", "[t]\n[t]", "x = 01", "x = \"\"\"", "x = [\"a\","] {
      #expect(throws: TOMLReader.ParseError.self) { try TOMLReader.parse(bad) }
    }
  }

  @Test func invalidConfigTomlRules() throws {
    for bad in ["", "  \n", "[inline]\nautosend = \"yes\"", "[transcription]\nprovider = \"whisper\"", "[clean\n"] {
      #expect(throws: (any Error).self) { try LegacySettings.convert(Data(bad.utf8)) }
    }
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
    let config = AppConfig(settings: loaded.settings, status: loaded.status, environment: root.environment(ffmpeg: true))
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
      ("clean.repeats_level", "3"), ("app.hotkey", "ctrl+option+space"), ("app.hotkey", "F20"), ("app.hotkey", "⌘+⇧+k"),
    ]
    for (key, value) in good { #expect(throws: Never.self) { try store.set(key, value: value) } }
    let bad: [(String, String)] = [
      ("transcription.provider", "whisper"), ("transcription.language", "EN"), ("transcription.language", "english"),
      ("swift_parakeet.model_version", "v4"), ("swift_parakeet.model_path", root.path + "/nope"),
      ("swift_parakeet.model_path", "a\nb"), ("debug.keep_logs", "yes"), ("clean.repeats_level", "4"),
      ("clean.repeats_level", "01"), ("app.hotkey", "space"), ("app.hotkey", "F21"), ("app.hotkey", "ctrl+a+b"),
      ("app.hotkey", "hyper+a"), ("inline.send_mode", "enter"), ("history.retention_days", "3"),
    ]
    for (key, value) in bad {
      #expect(throws: SettingsStore.InvalidSetting.self, "\(key)=\(value)") { try store.set(key, value: value) }
    }
    let s = store.load().settings
    #expect(s.transcription.provider == "elevenlabs" && s.hotkey == "⌘+⇧+k" && s.cleanup.repeatsLevel == 3)
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

  @Test func importConvertsSettingsAndListsSkippedKeys() throws {
    let root = try Root(); defer { root.cleanup() }
    let cli = root.url.appendingPathComponent("cli")
    let dest = root.url.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
    let text = try String(contentsOf: Self.fixtures.appendingPathComponent("full/config.toml"), encoding: .utf8)
    // config.toml broken: the last valid copy is used.
    try Data("[inline\n".utf8).write(to: cli.appendingPathComponent("config.toml"))
    try Data(text.utf8).write(to: cli.appendingPathComponent(".config.toml.last-good"))
    let result = LegacyImport.run(environment: ["KHULUMA_CONFIG_DIR": cli.path], home: root.url, destination: dest)
    guard case .imported(let receipt) = result.outcome else { Issue.record("\(result.outcome)"); return }
    #expect(receipt.settings == "imported")
    let skipped = receipt.skipped.map(\.path)
    #expect(skipped.contains(cli.appendingPathComponent("config.toml").path))
    #expect(skipped.contains(cli.appendingPathComponent(".config.toml.last-good").path + " extra.unused"))
    let loaded = SettingsStore(folder: dest).load()
    #expect(loaded.status.error == nil && loaded.settings.history.typingWpm == 55)

    // No config at all: defaults, no settings.json.
    let dest2 = root.url.appendingPathComponent("support2")
    try FileManager.default.removeItem(at: cli.appendingPathComponent("config.toml"))
    try FileManager.default.removeItem(at: cli.appendingPathComponent(".config.toml.last-good"))
    let second = LegacyImport.run(environment: ["KHULUMA_CONFIG_DIR": cli.path], home: root.url, destination: dest2)
    guard case .imported(let r2) = second.outcome else { Issue.record("\(second.outcome)"); return }
    #expect(r2.settings == "defaults")
    #expect(!FileManager.default.fileExists(atPath: dest2.appendingPathComponent("settings.json").path))
  }

  @Test func quotedKeysStayLiteral() throws {
    let doc = try TOMLReader.parse("""
      "inline.autosend" = false
      ["audio.sounds"]
      start = "/x.wav"
      [inline]
      "autosend" = true
      """)
    #expect(doc.values[#""inline.autosend""#] == .bool(false))
    #expect(doc.values[#""audio.sounds".start"#] == .string("/x.wav"))
    #expect(doc.values["inline.autosend"] == .bool(true))  // "autosend" is the bare key
    #expect(throws: TOMLReader.ParseError.self) { try TOMLReader.parse("[inline]\nautosend = true\n\"autosend\" = false") }
    // Not flattened onto the real keys: a dotted quoted key is skipped.
    let conversion = try LegacySettings.convert(Data("\"inline.autosend\" = false\n[\"audio.sounds\"]\nstart = \"/x.wav\"\n".utf8))
    #expect(conversion.settings.inline.autosend == true)
    #expect(conversion.settings.sounds.sound("start").path == "")
    #expect(conversion.skipped.map(\.key) == [#""audio.sounds".start"#, #""inline.autosend""#])
  }

  @Test func soundsPlaceholderExpandsAtRuntime() throws {
    let root = try Root(); defer { root.cleanup() }
    var settings = AppSettings()
    settings.sounds.events["start"] = .init(enabled: true, path: "$SOUNDS_DIR/khuluma/start.wav")
    settings.sounds.events["stop"] = .init(enabled: true, path: "${SOUNDS_DIR}/khuluma/error.wav")
    var env = root.environment(ffmpeg: true)
    env.soundsPlaceholder = root.path + "/data/sounds"
    try Data().write(to: root.url.appendingPathComponent("data/sounds/khuluma/start.wav"))
    let config = AppConfig(settings: settings, environment: env)
    #expect(config.sounds["start"]?.path == root.path + "/data/sounds/khuluma/start.wav")
    #expect(config.sounds["stop"]?.path == root.path + "/data/sounds/khuluma/error.wav")
    // Kept literally in settings.json.
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"))
    try store.save(settings)
    #expect(store.load().settings.sounds.sound("start").path == "$SOUNDS_DIR/khuluma/start.wav")
    let current = SettingsEnvironment.current(environment: ["SOUNDS_DIR": "/S"], home: root.url, appFolder: root.url)
    #expect(current.soundsPlaceholder == "/S" && current.soundsDir == "/S/khuluma")
  }

  @Test func missingSettingsWithLegacyConfigNeverAutosends() throws {
    let root = try Root(); defer { root.cleanup() }
    let legacy = root.url.appendingPathComponent("config/config.toml")
    try Data("[inline]\nautosend = true\n".utf8).write(to: legacy)
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"), legacyConfig: legacy)
    let loaded = store.load()
    #expect(loaded.status.source == "defaults" && loaded.status.error != nil)
    let config = AppConfig(settings: loaded.settings, status: loaded.status, environment: root.environment(ffmpeg: true))
    #expect(!config.inline.autosend && config.usingFallbackDefaults)
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

  @Test func importOfUnconvertibleConfigWritesSafeDefaults() throws {
    let root = try Root(); defer { root.cleanup() }
    let cli = root.url.appendingPathComponent("cli")
    let dest = root.url.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
    try Data("[inline\n".utf8).write(to: cli.appendingPathComponent("config.toml"))
    let result = LegacyImport.run(environment: ["KHULUMA_CONFIG_DIR": cli.path], home: root.url, destination: dest)
    guard case .imported(let receipt) = result.outcome else { Issue.record("\(result.outcome)"); return }
    #expect(receipt.settings == "defaults_no_autosend")
    let store = SettingsStore(folder: dest)
    let loaded = store.load()
    #expect(loaded.status.source == SettingsStore.importedDefaultsSource && loaded.status.error != nil)
    let config = AppConfig(settings: loaded.settings, status: loaded.status, environment: root.environment(ffmpeg: true))
    #expect(!config.inline.autosend && config.usingFallbackDefaults)
    // Choosing a setting in the app ends the warning.
    try store.set("inline.autosend", value: "true")
    #expect(store.load().status == .init(error: nil, source: "file"))
    #expect(store.load().settings.inline.autosend)
  }

  @Test func writesAfterAMissedImportKeepSendingOff() throws {
    let root = try Root(); defer { root.cleanup() }
    let legacy = root.url.appendingPathComponent("config/config.toml")
    try Data("[inline]\nautosend = true\n".utf8).write(to: legacy)
    let store = SettingsStore(folder: root.url.appendingPathComponent("app"), legacyConfig: legacy)
    func config() -> AppConfig {
      let loaded = store.load()
      return AppConfig(settings: loaded.settings, status: loaded.status, environment: root.environment(ffmpeg: true))
    }
    // Open Config creating the file, then other settings: still no sending, still warned.
    try store.ensureFile()
    #expect(!config().inline.autosend && config().config.error != nil)
    try store.set("audio.sounds.enabled", value: "false")
    try store.set("app.hotkey", value: "F5")
    #expect(!config().inline.autosend && config().config.error != nil)
    // Only an explicit choice turns sending on.
    try store.set("inline.autosend", value: "true")
    #expect(config().inline.autosend && config().config.error == nil)
    #expect(store.load().settings.hotkey == "F5" && !store.load().settings.sounds.enabled)
  }
}
