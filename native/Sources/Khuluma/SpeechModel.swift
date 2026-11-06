import FluidAudio
import Foundation
import KhulumaCore

/// FluidAudio's own answers about the Parakeet model: where its shared cache
/// keeps v3, which files a load-ready copy has, and the download.
enum SpeechModel {
  /// FluidAudio's shared cache, or in isolated runs a private folder
  /// (`AppRuntimePaths.defaultModelDirectory`, shared with the helper).
  static var defaultPath: String {
    AppRuntimePaths.defaultModelDirectory(
      environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser,
      sharedCache: AsrModels.defaultCacheDirectory(for: .v3)).path
  }

  /// One download at a time across processes, beside the model folder (so
  /// an isolated run locks its own folder, never the shared cache).
  static var downloadLockPath: String {
    (defaultPath as NSString).deletingLastPathComponent + "/.khuluma-download.lock"
  }

  static func requiredFiles(version: String) -> Set<String> {
    let v2 = version == "v2"
    return (v2 ? ModelNames.ASR.requiredModels : ModelNames.ASR.requiredModelsV3(precision: .int8))
      .union([ModelNames.ASR.vocabularyFile])
  }

  static func isComplete(_ path: String, version: String) -> Bool {
    ModelBundleCheck.isComplete(path, required: requiredFiles(version: version))
  }

  /// The default cache only ever holds the downloaded v3.
  static func isCompleteV3(_ path: String) -> Bool { isComplete(path, version: "v3") }

  /// Into `defaultPath`, from this process. Only a folder that exists and
  /// fails `ModelBundleCheck` (an interrupted download) is replaced
  /// (`force` deletes it first): FluidAudio's own check would otherwise take
  /// its bare folders for a finished model. A complete bundle is never
  /// forced.
  static func download(progress: @escaping @Sendable (Double) -> Void,
                       done: @escaping @Sendable (Result<String, Error>) -> Void) {
    let target = URL(fileURLWithPath: defaultPath, isDirectory: true)
    let repair = FileManager.default.fileExists(atPath: target.path) && !isCompleteV3(target.path)
    Task.detached(priority: .utility) {
      do {
        let url = try await AsrModels.download(to: target, force: repair, version: .v3) { update in
          progress(update.fractionCompleted)
        }
        done(.success(url.path))
      } catch {
        done(.failure(error))
      }
    }
  }

  static let environment = ModelProvisioner.Environment(
    isComplete: isCompleteV3,
    lockDownload: { FileLock.tryLock(downloadLockPath) },
    download: download,
    schedule: { delay, work in DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work) })
}
