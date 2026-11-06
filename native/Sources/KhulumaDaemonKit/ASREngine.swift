import Foundation
@preconcurrency import FluidAudio

private struct LoadedModelKey: Equatable {
  let path: String
  let version: String
}

/// The model an engine has loaded, readable without waiting for the engine
/// (pings must answer while a transcription runs).
final class LoadedModelSnapshot: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (path: String, version: String)?

  var current: (path: String, version: String)? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(path: String, version: String) {
    lock.lock()
    value = (path, version)
    lock.unlock()
  }
}

public struct TranscriptionResult: Sendable {
  public let text: String
  public let model: String
  public let durationMs: Int
}

/// Serializes async critical sections. Actor methods are reentrant at `await`
/// points, so actor isolation alone does not stop two callers from
/// interleaving inside FluidAudio.
actor SerialGate {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      // Ownership passes straight to the next waiter; `busy` stays true.
      waiters.removeFirst().resume()
    }
  }

  func withExclusiveAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
    await acquire()
    do {
      let value = try await body()
      release()
      return value
    } catch {
      release()
      throw error
    }
  }
}

/// Parakeet (FluidAudio) speech recognition with a warm, reusable model.
///
/// FluidAudio's `AsrManager` is an actor, but actors are reentrant at `await`
/// points and it keeps per-source decoder state, so two transcriptions must not
/// interleave. Model loading and transcription run one at a time through a gate.
public actor ASREngine {
  private var currentKey: LoadedModelKey?
  private var manager: AsrManager?
  private let gate = SerialGate()
  private let snapshot = LoadedModelSnapshot()

  public init() {}

  /// The loaded model as the last request that used it named it (path
  /// string and version label), or nil before any load succeeds. Set as
  /// soon as a load commits, even if the request then fails.
  public nonisolated var loadedModel: (path: String, version: String)? { snapshot.current }

  /// `requestedPath` is the model path as the client sent it, reported back
  /// by `loadedModel` (defaults to `modelURL.path`).
  public func warmup(
    modelURL: URL, modelVersion: String, requestedPath: String? = nil
  ) async throws -> (model: String, durationMs: Int) {
    let version = try Self.parseModelVersion(modelVersion)
    return try await gate.withExclusiveAccess {
      let started = ContinuousClock.now
      let wasLoaded = await self.isLoaded(path: modelURL.path, version: modelVersion)
      try await self.ensureInitialized(
        modelURL: modelURL, version: version, versionLabel: modelVersion, requestedPath: requestedPath)
      // Loading the model isn't enough: Core ML specialises it on the first
      // prediction (tens of seconds cold). Run one second of silence now so
      // "ready" means the next real take is fast.
      if !wasLoaded { await self.primeFirstPrediction(version: version) }
      return (modelURL.lastPathComponent, Self.elapsedMs(since: started))
    }
  }

  public func transcribe(
    audioURL: URL, modelURL: URL, modelVersion: String, requestedPath: String? = nil
  ) async throws -> TranscriptionResult {
    let version = try Self.parseModelVersion(modelVersion)
    return try await gate.withExclusiveAccess {
      try await self.runTranscription(
        audioURL: audioURL, modelURL: modelURL, version: version, versionLabel: modelVersion,
        requestedPath: requestedPath)
    }
  }

  private func runTranscription(
    audioURL: URL,
    modelURL: URL,
    version: AsrModelVersion,
    versionLabel: String,
    requestedPath: String?
  ) async throws -> TranscriptionResult {
    try await ensureInitialized(
      modelURL: modelURL, version: version, versionLabel: versionLabel, requestedPath: requestedPath)
    guard let manager else {
      throw DaemonServiceError.invalidRequest("ASR manager was not initialized")
    }

    let started = ContinuousClock.now
    // A fresh decoder state per take, as the per-source state was before.
    var decoderState = TdtDecoderState.make(decoderLayers: version.decoderLayers)
    let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
    return TranscriptionResult(
      text: result.text,
      model: modelURL.lastPathComponent,
      durationMs: Self.elapsedMs(since: started)
    )
  }

  private func ensureInitialized(
    modelURL: URL, version: AsrModelVersion, versionLabel: String, requestedPath: String?
  ) async throws {
    let key = LoadedModelKey(path: modelURL.path, version: versionLabel)
    if currentKey == key, manager != nil {
      snapshot.set(path: requestedPath ?? modelURL.path, version: versionLabel)
      return
    }

    guard AsrModels.modelsExist(at: modelURL, version: version) else {
      throw DaemonServiceError.modelPathInvalid(modelURL.path)
    }

    let configuration = AsrModels.defaultConfiguration()
    let models = try await AsrModels.load(
      from: modelURL,
      configuration: configuration,
      version: version
    )

    let newManager = AsrManager()
    try await newManager.loadModels(models)
    manager = newManager
    currentKey = key
    snapshot.set(path: requestedPath ?? modelURL.path, version: versionLabel)
  }

  private func isLoaded(path: String, version: String) -> Bool {
    currentKey == LoadedModelKey(path: path, version: version) && manager != nil
  }

  /// One second of silence through the freshly loaded model. Failures are
  /// ignored: a real take reports its own errors.
  private func primeFirstPrediction(version: AsrModelVersion) async {
    guard let manager else { return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("khulumad-prime-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let samples = 16_000
    var header = Data()
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + samples * 2))
    header.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(16_000); le32(32_000); le16(2); le16(16)
    header.append(contentsOf: Array("data".utf8)); le32(UInt32(samples * 2))
    guard (try? (header + Data(count: samples * 2)).write(to: url)) != nil else { return }
    var decoderState = TdtDecoderState.make(decoderLayers: version.decoderLayers)
    _ = try? await manager.transcribe(url, decoderState: &decoderState)
  }

  static func parseModelVersion(_ raw: String) throws -> AsrModelVersion {
    switch raw.lowercased() {
    case "v2":
      return .v2
    case "v3":
      return .v3
    default:
      throw DaemonServiceError.unsupportedModelVersion(raw)
    }
  }

  private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
    let elapsed = start.duration(to: ContinuousClock.now)
    let millis = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    return max(0, millis)
  }
}
