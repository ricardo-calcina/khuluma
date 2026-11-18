import Foundation
import Testing
@testable import KhulumaCore

@Suite struct SoundsAndPermissionsTests {
  /// An environment whose files are exactly `files`.
  func env(bundled: String? = "/App/Resources/sounds", files: Set<String>) -> SettingsEnvironment {
    SettingsEnvironment(appFolder: URL(fileURLWithPath: "/support"), home: "/home", bundledSoundsDir: bundled, defaultSocketPath: "/sock", keyAvailable: false,
                        fileExists: { files.contains($0) }, directoryExists: { _ in false })
  }

  func settings(_ path: String, event: String = "start") -> AppSettings {
    var s = AppSettings()
    s.sounds.events[event] = .init(enabled: true, path: path)
    return s
  }

  @Test func defaultsResolveToTheBundledSounds() {
    let e = env(files: ["/App/Resources/sounds/start.wav"])
    #expect(AppSettings().soundPath("start", in: e) == "/App/Resources/sounds/start.wav")
    // A bundle without that file: silent.
    #expect(AppSettings().soundPath("stop", in: e) == nil)
    #expect(AppSettings().soundPath("error", in: e) == nil)
  }

  @Test func withoutABundleNothingCrashesAndMissingIsSilent() {
    let e = env(bundled: nil, files: [])
    for event in AppSettings.soundEvents { #expect(AppSettings().soundPath(event, in: e) == nil) }
    let config = AppConfig(settings: AppSettings(), environment: e)
    #expect(config.sounds.values.allSatisfy { !$0.enabled && $0.path == nil })
    #expect(env(bundled: "", files: []).bundledSound("start.wav") == nil)
  }

  @Test func aConfiguredFileIsUsedOnlyWhileItExists() {
    let bundled = "/App/Resources/sounds/start.wav"
    let mine = "/support/sounds/Chime.wav"
    #expect(settings(mine).soundPath("start", in: env(files: [mine, bundled])) == mine)
    // Gone: silent, not the bundled default (the Sounds page shows it missing).
    #expect(settings(mine).soundPath("start", in: env(files: [bundled])) == nil)
    #expect(settings("~/x.wav").soundPath("start", in: env(files: ["/home/x.wav"])) == "/home/x.wav")
  }

  @Test func theBuildScriptShipsEveryDefaultSound() throws {
    // The script copies assets/sounds/khuluma/*.wav; one file per event.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("assets/sounds/khuluma").path)
    #expect(Set(names) == Set(AppSettings.soundEvents.map { $0 + ".wav" }))
  }

  // MARK: Permissions

  @Test func deliveryFailsWithoutPostEventAccess() {
    let denied = PermissionPolicy.deliveryFailure(accessibilityTrusted: true, postEventAllowed: false)
    #expect(denied?.code == PermissionPolicy.postEventMissingCode && denied?.domain == "Khuluma")
    #expect(denied?.localizedDescription == "Couldn't paste: allow Khuluma to control the keyboard (Settings)")
    #expect(PermissionPolicy.isKeyboardFailure(denied!.localizedDescription))
    #expect(PermissionPolicy.deliveryFailure(accessibilityTrusted: false, postEventAllowed: true)?.code
            == PermissionPolicy.accessibilityMissingCode)
    #expect(PermissionPolicy.deliveryFailure(accessibilityTrusted: true, postEventAllowed: true) == nil)
    #expect(!PermissionPolicy.isKeyboardFailure("Accessibility permission missing"))
    // Both a refused post-event and a revoked Accessibility permission link to the pane.
    let ax = PermissionPolicy.deliveryFailure(accessibilityTrusted: false, postEventAllowed: true)!
    #expect(PermissionPolicy.notice(forFailure: ax.localizedDescription) == PermissionPolicy.keyboardNotice)
    #expect(PermissionPolicy.notice(forFailure: denied!.localizedDescription) == PermissionPolicy.keyboardNotice)
    #expect(PermissionPolicy.notice(forFailure: "something else") == nil)
  }

  @Test func aFailedDeliveryIsNotCounted() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-perm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let rec = TakeRecorder(root: root, settings: .init(keepLogs: false), now: { Date(timeIntervalSince1970: 1_793_870_042) },
                           timeZone: TimeZone(identifier: "Europe/London")!, trash: { _ in }, temporaryRoots: [])
    var take = TakeRecord(takeId: "pf", status: "paste_failed", delivered: false)
    take.text = "Hello."
    #expect(!TakeRecorder.wantsUsage(take))
    #expect(rec.record(take) == .init(history: .written, usage: .notNeeded))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("usage.json").path))
  }

  @Test func microphoneAndKeyboardNoticesOpenTheRightPanes() {
    #expect(PermissionPolicy.microphoneNotice(for: .denied) == PermissionPolicy.microphoneNotice)
    #expect(PermissionPolicy.microphoneNotice(for: .authorized) == nil)
    #expect(PermissionPolicy.microphoneNotice(for: .notDetermined) == nil)
    #expect(PermissionPolicy.Pane.microphone.url.hasSuffix("Privacy_Microphone"))
    #expect(PermissionPolicy.Pane.keyboard.url.hasSuffix("Privacy_Accessibility"))
    #expect(PermissionPolicy.keyboardNotice.pane == .keyboard)
  }
}
