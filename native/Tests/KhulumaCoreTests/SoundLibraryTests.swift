import Foundation
import Testing
@testable import KhulumaCore

/// SoundLibrary's folder listing and "Choose File…" import, SoundChoice's
/// pop-up state, and the store's per-event sound keys.
struct SoundLibraryTests {
  private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-soundlib-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func write(_ url: URL, _ bytes: [UInt8] = [1]) throws {
    try Data(bytes).write(to: url)
  }

  @Test func listsOnlyVisibleAudioFilesSorted() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let library = SoundLibrary(directory: dir)
    try write(dir.appendingPathComponent("beta.WAV"))
    try write(dir.appendingPathComponent("Alpha.aiff"))
    try write(dir.appendingPathComponent("note.txt"))
    try write(dir.appendingPathComponent(".hidden.wav"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub.wav", isDirectory: true),
                                            withIntermediateDirectories: true)
    #expect(library.files().map(\.lastPathComponent) == ["Alpha.aiff", "beta.WAV"])
  }

  @Test func missingFolderListsNothing() {
    let library = SoundLibrary(directory: URL(fileURLWithPath: "/tmp/khuluma-no-such-\(UUID().uuidString)"))
    #expect(library.files() == [])
  }

  @Test func importCopies0600IntoA0700Folder() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let library = SoundLibrary(directory: dir.appendingPathComponent("sounds"))
    let source = dir.appendingPathComponent("Tone.wav")
    try write(source, [1, 2, 3])
    let imported = try library.importFile(source)
    #expect(imported.lastPathComponent == "Tone.wav")
    let fileAttrs = try FileManager.default.attributesOfItem(atPath: imported.path)
    #expect(fileAttrs[.posixPermissions] as? Int == 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: library.directory.path)
    #expect(dirAttrs[.posixPermissions] as? Int == 0o700)
  }

  @Test func importingIdenticalBytesReturnsTheSameFile() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let library = SoundLibrary(directory: dir)
    let source = dir.appendingPathComponent("Tone.wav")
    try write(source, [9])
    let first = try library.importFile(source)
    let again = try library.importFile(source)
    #expect(first == again)
    #expect(library.files().count == 1)
  }

  @Test func aDifferentFileWithTheSameNameGetsNumbered() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let library = SoundLibrary(directory: dir)
    let a = dir.appendingPathComponent("a"); let b = dir.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    try write(a.appendingPathComponent("Tone.wav"), [1])
    try write(b.appendingPathComponent("Tone.wav"), [2])
    _ = try library.importFile(a.appendingPathComponent("Tone.wav"))
    let second = try library.importFile(b.appendingPathComponent("Tone.wav"))
    #expect(second.lastPathComponent == "Tone 2.wav")
  }

  @Test func importRejectsOtherExtensions() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let library = SoundLibrary(directory: dir)
    let source = dir.appendingPathComponent("notes.txt")
    try write(source)
    #expect(throws: (any Error).self) { try library.importFile(source) }
  }
}

struct SoundChoiceTests {
  private let exists: (String) -> Bool = { $0.hasPrefix("/ok/") }
  private let identity: (String) -> String = { $0 }

  @Test func disabledIsNone() {
    let sound = AppSettings.Sound(enabled: false, path: "/ok/a.wav")
    #expect(SoundChoice.current(sound: sound, fileExists: exists, expand: identity) == .none)
  }

  @Test func emptyPathIsStandard() {
    let sound = AppSettings.Sound(enabled: true, path: "")
    #expect(SoundChoice.current(sound: sound, fileExists: exists, expand: identity) == .standard)
  }

  @Test func anExistingPathIsFile() {
    let sound = AppSettings.Sound(enabled: true, path: "/ok/a.wav")
    #expect(SoundChoice.current(sound: sound, fileExists: exists, expand: identity) == .file("/ok/a.wav"))
  }

  @Test func aGonePathIsMissing() {
    let sound = AppSettings.Sound(enabled: true, path: "/gone/a.wav")
    #expect(SoundChoice.current(sound: sound, fileExists: exists, expand: identity) == .missing("/gone/a.wav"))
  }
}

struct SoundSettingStoreTests {
  @Test func setSoundWritesBothInOneUpdate() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-soundstore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let wav = root.appendingPathComponent("Ding.wav")
    try Data([1]).write(to: wav)
    let store = SettingsStore(folder: root.appendingPathComponent("app"))
    // An unknown key already in the file must survive the write.
    let settings = AppSettings()
    _ = try store.save(settings)
    var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any] ?? [:]
    raw["mystery"] = ["kept": true]
    try JSONSerialization.data(withJSONObject: raw).write(to: store.url)
    try store.setSound(event: "start", path: wav.path, enabled: true)
    var loaded = store.load().settings
    #expect(loaded.sounds.sound("start") == AppSettings.Sound(enabled: true, path: wav.path))
    raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any] ?? [:]
    #expect((raw["mystery"] as? [String: Any])?["kept"] as? Bool == true)
    // "" resets to the bundled default while keeping it enabled.
    try store.setSound(event: "start", path: "", enabled: true)
    loaded = store.load().settings
    #expect(loaded.sounds.sound("start") == AppSettings.Sound(enabled: true, path: ""))
  }

  @Test func setSoundRejectsBadValues() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-soundstore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SettingsStore(folder: root.appendingPathComponent("app"))
    #expect(throws: (any Error).self) { try store.setSound(event: "start", path: "relative/x.wav", enabled: true) }
    #expect(throws: (any Error).self) { try store.setSound(event: "start", path: "/no/such/file.wav", enabled: true) }
    #expect(throws: (any Error).self) { try store.setSound(event: "nope", path: "", enabled: true) }
  }

  @Test func perEventKeysValidate() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-soundstore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let wav = root.appendingPathComponent("Ding.wav")
    try Data([1]).write(to: wav)
    let store = SettingsStore(folder: root.appendingPathComponent("app"))
    #expect(throws: Never.self) { try store.set("audio.sounds.start.enabled", value: "false") }
    #expect(throws: Never.self) { try store.set("audio.sounds.start.path", value: wav.path) }
    #expect(throws: (any Error).self) { try store.set("audio.sounds.start.path", value: "rel.wav") }
    #expect(throws: (any Error).self) { try store.set("audio.sounds.unknown.enabled", value: "true") }
  }
}
