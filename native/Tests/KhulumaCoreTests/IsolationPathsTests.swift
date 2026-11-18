import Foundation
import Testing
@testable import KhulumaCore

/// Isolated runs (KHULUMA_SUPPORT_DIR etc.) never touch the user's shared
/// model cache or the daily app folder; ordinary runs are unchanged.
struct IsolationPathsTests {
  let home = URL(fileURLWithPath: "/Users/x")
  let shared = URL(fileURLWithPath: "/Users/x/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3")
  let isolated = ["KHULUMA_SUPPORT_DIR": "/fixture/support", "KHULUMA_LOG_DIR": "/fixture/logs",
                  "KHULUMA_DEFAULTS_SUITE": "com.ricardo-nth.khuluma.test"]

  @Test func modelFolderIsTheSharedCacheOnlyWhenNotIsolated() {
    #expect(AppRuntimePaths.defaultModelDirectory(environment: [:], home: home, sharedCache: shared) == shared)
    // An override alone doesn't redirect an ordinary run.
    #expect(AppRuntimePaths.defaultModelDirectory(
      environment: ["KHULUMA_DEFAULT_MODEL_DIR": "/elsewhere"], home: home, sharedCache: shared) == shared)
    #expect(AppRuntimePaths.defaultModelDirectory(environment: isolated, home: home, sharedCache: shared).path
            == "/fixture/support/models/parakeet-tdt-0.6b-v3")
    var overridden = isolated
    // The override is the parent models folder; FluidAudio's folder name goes under it.
    overridden["KHULUMA_DEFAULT_MODEL_DIR"] = "/fixture/models"
    #expect(AppRuntimePaths.defaultModelDirectory(environment: overridden, home: home, sharedCache: shared).path
            == "/fixture/models/parakeet-tdt-0.6b-v3")
    overridden["KHULUMA_DEFAULT_MODEL_DIR"] = ""
    #expect(AppRuntimePaths.defaultModelDirectory(environment: overridden, home: home, sharedCache: shared).path
            == "/fixture/support/models/parakeet-tdt-0.6b-v3")
  }

  @Test func isolatedDataOverridesCantPointAtRealData() {
    for (key, value) in [("KHULUMA_DEFAULT_MODEL_DIR", "/Users/x/Library/Application Support/FluidAudio/Models"),
                         ("KHULUMA_DEFAULT_MODEL_DIR", "/Users/x/Library/Application Support/Khuluma/models"),
                         ("KHULUMA_DEFAULT_MODEL_DIR", "/Users/x/Library/Application Support/Khuluma/../FluidAudio/Models"),
                         // APFS is case-insensitive.
                         ("KHULUMA_DEFAULT_MODEL_DIR", "/Users/x/library/application support/fluidaudio/Models")] {
      var env = isolated
      env[key] = value
      let issue = AppRuntimePaths.isolationIssue(environment: env, home: home)
      #expect(issue?.contains(key) == true, "\(key)=\(value): \(issue ?? "nil")")
    }
    // Elsewhere is fine as far as this check goes (later checks still apply).
    var env = isolated
    env["KHULUMA_DEFAULT_MODEL_DIR"] = "/fixture/models"
    #expect(AppRuntimePaths.isolationIssue(environment: env, home: home)?.contains("KHULUMA_DEFAULT_MODEL_DIR") != true)
  }

  /// Isolated runs: a configured model_path into real data is ignored.
  @Test func isolatedRunsIgnoreAModelPathInRealData() {
    let home = URL(fileURLWithPath: "/Users/x")
    var env = SettingsEnvironment.current(environment: isolated, home: home, appFolder: URL(fileURLWithPath: "/fixture/support"))
    env.defaultModelPath = "/fixture/support/models/parakeet-tdt-0.6b-v3"
    env.modelAvailable = { _, _ in true }
    var settings = AppSettings()
    settings.transcription.modelPath = "/Users/x/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
    #expect(env.isForbiddenModelPath(settings.transcription.modelPath))
    #expect(settings.resolvedModel(in: env)?.path == "/fixture/support/models/parakeet-tdt-0.6b-v3")
    settings.transcription.modelPath = "/fixture/own-model"
    #expect(settings.resolvedModel(in: env)?.path == "/fixture/own-model")
    // Not isolated: honoured as before.
    var normal = SettingsEnvironment.current(environment: [:], home: home, appFolder: URL(fileURLWithPath: "/a"))
    normal.modelAvailable = { _, _ in true }
    settings.transcription.modelPath = "/Users/x/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
    #expect(settings.resolvedModel(in: normal)?.path == settings.transcription.modelPath)
  }

  /// A symlink to real data with a child that doesn't exist yet still
  /// resolves into real data (through its nearest existing ancestor).
  @Test func aSymlinkToRealDataWithANewChildIsRefused() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-link-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home")
    let cache = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("innocent")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cache)
    var env = isolated
    env["KHULUMA_DEFAULT_MODEL_DIR"] = link.appendingPathComponent("new-child").path
    #expect(AppRuntimePaths.isolationIssue(environment: env, home: home)?.contains("KHULUMA_DEFAULT_MODEL_DIR") == true)
    #expect(AppRuntimePaths.isRealData(link.appendingPathComponent("a/b").path, home: home))
    #expect(!AppRuntimePaths.isRealData(base.appendingPathComponent("elsewhere/x").path, home: home))
  }
}
