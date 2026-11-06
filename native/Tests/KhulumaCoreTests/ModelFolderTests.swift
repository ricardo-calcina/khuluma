import FluidAudio
import Foundation
import Testing
@testable import KhulumaCore

/// The model folder the app resolves is where FluidAudio's download(to:)
/// actually writes: `<parent>/<repo folder name>` (0.15.x: no "-coreml").
struct ModelFolderTests {
  @Test func resolverTargetMatchesFluidAudiosDownloadFolder() {
    let shared = AsrModels.defaultCacheDirectory(for: .v3)
    #expect(shared.lastPathComponent == Repo.parakeetV3.folderName)
    #expect(!shared.lastPathComponent.hasSuffix("-coreml"))
    let isolated = ["KHULUMA_SUPPORT_DIR": "/fixture/support", "KHULUMA_LOG_DIR": "/fixture/logs",
                    "KHULUMA_DEFAULTS_SUITE": "com.ricardo-nth.khuluma.test", "KHULUMA_DEFAULT_MODEL_DIR": "/fixture/models"]
    let target = AppRuntimePaths.defaultModelDirectory(environment: isolated, home: URL(fileURLWithPath: "/Users/x"),
                                                      sharedCache: shared)
    // download(to: target) writes into target.parent/<repo.folderName>.
    #expect(target.deletingLastPathComponent().appendingPathComponent(Repo.parakeetV3.folderName).path == target.path)
    #expect(target.path == "/fixture/models/" + Repo.parakeetV3.folderName)
  }
}
