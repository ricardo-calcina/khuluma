import Foundation

/// Converts the CLI's `config.toml` into `AppSettings`, carrying over only
/// the keys the app uses. Same validity rules as the CLI's `config_load`
/// (an empty file, a TOML error, a non-boolean switch or an unknown provider
/// make the file invalid). Everything not carried over is listed with why.
public enum LegacySettings {
  public struct Conversion: Sendable {
    public var settings: AppSettings
    /// Dotted TOML key and why it wasn't converted.
    public var skipped: [(key: String, reason: String)]
  }

  static let boolKeys: Set<String> = [
    "audio.sounds.enabled", "audio.sounds.start_enabled", "audio.sounds.stop_enabled",
    "audio.sounds.process_enabled", "audio.sounds.error_enabled", "audio.sounds.cancel_enabled",
    "inline.autosend", "inline.process_sound", "debug.keep_logs", "app.supervise_daemon", "clean.enabled",
  ]

  public static func convert(_ data: Data) throws -> Conversion {
    guard let text = String(data: data, encoding: .utf8) else { throw TOMLReader.ParseError(line: 0, message: "not UTF-8") }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TOMLReader.ParseError(line: 0, message: "the file is empty")
    }
    let doc = try TOMLReader.parse(text)
    for key in boolKeys {
      if let v = doc.values[key], case .bool = v {} else if doc.values[key] != nil || doc.unreadable.contains(where: { $0.path == key }) {
        throw TOMLReader.ParseError(line: 0, message: "\(key) must be true or false")
      }
    }
    if let v = doc.values["transcription.provider"], v != .string("parakeet"), v != .string("elevenlabs") {
      throw TOMLReader.ParseError(line: 0, message: "transcription.provider must be parakeet or elevenlabs")
    }
    if doc.unreadable.contains(where: { $0.path == "transcription.provider" }) {
      throw TOMLReader.ParseError(line: 0, message: "transcription.provider must be parakeet or elevenlabs")
    }

    var s = AppSettings()
    var skipped = doc.unreadable.map { (key: $0.path, reason: $0.reason) }
    for (key, value) in doc.values.sorted(by: { $0.key < $1.key }) {
      func string() -> String? { if case .string(let x) = value { return x }; skipped.append((key, "expected a string")); return nil }
      func bool() -> Bool? { if case .bool(let x) = value { return x }; skipped.append((key, "expected true or false")); return nil }
      func int(_ range: ClosedRange<Int>? = nil) -> Int? {
        if case .int(let x) = value, range?.contains(x) ?? true { return x }
        skipped.append((key, range.map { "expected a whole number \($0.lowerBound)-\($0.upperBound)" } ?? "expected a whole number"))
        return nil
      }
      let parts = key.split(separator: ".").map(String.init)
      switch key {
      case "app.hotkey": if let v = string() { s.hotkey = v }
      case "app.supervise_daemon": if let v = bool() { s.app.superviseDaemon = v }
      case "audio.sounds.enabled": if let v = bool() { s.sounds.enabled = v }
      case "inline.autosend": if let v = bool() { s.inline.autosend = v }
      case "inline.process_sound": if let v = bool() { s.inline.processSound = v }
      case "inline.paste_target": if let v = string() { s.inline.pasteTarget = AppSettings.normalizedPasteTarget(v) }
      case "inline.send_mode": if let v = string() { s.inline.sendMode = AppSettings.normalizedSendMode(v) }
      case "clean.enabled": if let v = bool() { s.cleanup.enabled = v }
      case "clean.repeats_level": if let v = int(0...3) { s.cleanup.repeatsLevel = v }
      case "transcription.provider": if let v = string() { s.transcription.provider = v }
      case "transcription.language": if let v = string() { s.transcription.language = v }
      case "swift_parakeet.model_path": if let v = string() { s.transcription.modelPath = v }
      case "swift_parakeet.model_version": if let v = string() { s.transcription.modelVersion = v }
      case "swift_parakeet.socket_path": if let v = string() { s.transcription.socketPath = v }
      case "debug.keep_logs": if let v = bool() { s.debug.keepLogs = v }
      case "history.retention_days": if let v = int(0...Int.max) { s.history.retentionDays = v }
      case "history.audio_retention_days": if let v = int(0...Int.max) { s.history.audioRetentionDays = v }
      case "history.typing_wpm": if let v = int(1...Int.max) { s.history.typingWpm = v }
      default:
        if parts.count == 3, parts[0] == "audio", parts[1] == "sounds" {
          let name = parts[2]
          let event = name.hasSuffix("_enabled") ? String(name.dropLast("_enabled".count)) : name
          if AppSettings.soundEvents.contains(event) {
            var sound = s.sounds.sound(event)
            if name.hasSuffix("_enabled") { if let v = bool() { sound.enabled = v } }
            else if let v = string() { sound.path = v }
            s.sounds.events[event] = sound
            continue
          }
        }
        skipped.append((key, "not used by the app"))
      }
    }
    return Conversion(settings: s, skipped: skipped.sorted { $0.key < $1.key })
  }

  /// `config.toml`, else `.config.toml.last-good` when the main file is
  /// invalid. nil when neither converts (the app keeps its defaults); the
  /// errors are in `problems`.
  public static func convert(configDir: URL) -> (conversion: Conversion?, source: URL?, problems: [(path: String, reason: String)]) {
    var problems: [(path: String, reason: String)] = []
    for name in ["config.toml", ".config.toml.last-good"] {
      let url = configDir.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url) else {
        if FileManager.default.fileExists(atPath: url.path) { problems.append((url.path, "unreadable")) }
        continue
      }
      do { return (try convert(data), url, problems) } catch {
        problems.append((url.path, "not converted: " + error.localizedDescription))
      }
    }
    return (nil, nil, problems)
  }
}
