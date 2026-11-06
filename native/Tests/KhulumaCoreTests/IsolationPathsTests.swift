import Foundation
import Testing
@testable import KhulumaCore

/// Isolated runs (KHULUMA_SUPPORT_DIR etc.) never touch the user's shared
/// model cache, shell files, sounds or $TMPDIR; ordinary runs are unchanged.
struct IsolationPathsTests {
  let home = URL(fileURLWithPath: "/Users/x")
  let shared = URL(fileURLWithPath: "/Users/x/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")
  let isolated = ["KHULUMA_SUPPORT_DIR": "/fixture/support", "KHULUMA_LOG_DIR": "/fixture/logs",
                  "KHULUMA_DEFAULTS_SUITE": "com.ricardo-nth.khuluma.test"]

  @Test func modelFolderIsTheSharedCacheOnlyWhenNotIsolated() {
    #expect(AppRuntimePaths.defaultModelDirectory(environment: [:], home: home, sharedCache: shared) == shared)
    // An override alone doesn't redirect an ordinary run.
    #expect(AppRuntimePaths.defaultModelDirectory(
      environment: ["KHULUMA_DEFAULT_MODEL_DIR": "/elsewhere"], home: home, sharedCache: shared) == shared)
    #expect(AppRuntimePaths.defaultModelDirectory(environment: isolated, home: home, sharedCache: shared).path
            == "/fixture/support/models/parakeet-tdt-0.6b-v3-coreml")
    var overridden = isolated
    overridden["KHULUMA_DEFAULT_MODEL_DIR"] = "/fixture/model"
    #expect(AppRuntimePaths.defaultModelDirectory(environment: overridden, home: home, sharedCache: shared).path
            == "/fixture/model")
    overridden["KHULUMA_DEFAULT_MODEL_DIR"] = ""
    #expect(AppRuntimePaths.defaultModelDirectory(environment: overridden, home: home, sharedCache: shared).path
            == "/fixture/support/models/parakeet-tdt-0.6b-v3-coreml")
  }

  @Test func soundsAndModelsStayInTheAppFolderWhenIsolated() {
    let normal = SettingsEnvironment.current(environment: [:], home: home, appFolder: URL(fileURLWithPath: "/a"))
    #expect(normal.soundsDir == "/Users/x/.local/share/sounds/khuluma")
    #expect(normal.modelsDir == "/Users/x/.local/share/khuluma/models")
    let private_ = SettingsEnvironment.current(environment: isolated, home: home, appFolder: URL(fileURLWithPath: "/fixture/support"))
    #expect(private_.soundsDir == "/fixture/support/sounds/khuluma")
    #expect(private_.modelsDir == "/fixture/support/khuluma/models")
    #expect(!private_.soundsDir.hasPrefix("/Users/x"))
    // Named explicitly: respected.
    var named = isolated
    named["SOUNDS_DIR"] = "/fixture/sounds"
    #expect(SettingsEnvironment.current(environment: named, home: home).soundsDir == "/fixture/sounds/khuluma")
    named = isolated
    named["XDG_DATA_HOME"] = "/fixture/data"
    #expect(SettingsEnvironment.current(environment: named, home: home).soundsDir == "/fixture/data/sounds/khuluma")
  }

  @Test func legacyTimedOutFolderIsInsideSupportWhenIsolated() {
    #expect(TimedOutTakes.legacyDirectory(environment: isolated, home: home).path
            == "/fixture/support/temporary/khuluma-timed-out")
    #expect(TimedOutTakes.legacyDirectory(environment: [:], home: home).path
            == FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-timed-out").path)
  }
}
