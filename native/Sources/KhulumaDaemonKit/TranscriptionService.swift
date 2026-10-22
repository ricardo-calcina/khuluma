import Foundation

/// Answers one decoded daemon request. The socket server depends on this
/// protocol so it can be tested without loading a model.
public protocol DaemonRequestHandling: Sendable {
  func handle(_ request: DaemonRequest) async -> DaemonResponse
}

/// Maps daemon requests onto the shared `ASREngine`.
public actor TranscriptionService: DaemonRequestHandling {
  private let engine: ASREngine
  private var activeRequests = 0
  /// Identifies this daemon process in pings.
  public nonisolated let generation = UUID().uuidString.lowercased()

  public init(engine: ASREngine = ASREngine()) {
    self.engine = engine
  }

  public func handle(_ request: DaemonRequest) async -> DaemonResponse {
    if request.op == .ping {
      return DaemonResponse(
        id: request.id,
        ok: true,
        durationMs: 0,
        message: "ok",
        version: DaemonInfo.daemonVersion,
        activeRequests: activeRequests,
        pid: Int(getpid()),
        generation: generation,
        modelLoaded: loadedModel()
      )
    }

    activeRequests += 1
    defer { activeRequests -= 1 }

    do {
      switch request.op {
      case .ping:
        preconditionFailure("handled above")

      case .warmup:
        let (modelURL, modelVersion) = try resolveModelRequest(request)
        let result = try await engine.warmup(
          modelURL: modelURL, modelVersion: modelVersion, requestedPath: request.modelPath)
        return DaemonResponse(
          id: request.id,
          ok: true,
          model: result.model,
          durationMs: result.durationMs,
          message: "warmed",
          modelLoaded: loadedModel()
        )

      case .transcribe:
        guard let wavPath = request.wavPath, !wavPath.isEmpty else {
          throw DaemonServiceError.wavPathMissing
        }
        let wavURL = URL(fileURLWithPath: wavPath)
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
          throw DaemonServiceError.wavPathInvalid(wavURL.path)
        }

        let (modelURL, modelVersion) = try resolveModelRequest(request)
        let result = try await engine.transcribe(
          audioURL: wavURL, modelURL: modelURL, modelVersion: modelVersion, requestedPath: request.modelPath)
        return DaemonResponse(
          id: request.id,
          ok: true,
          text: result.text,
          model: result.model,
          durationMs: result.durationMs
        )
      }
    } catch let error as DaemonServiceError {
      return .failure(id: request.id, code: error.errorCode, message: error.localizedDescription)
    } catch {
      return .failure(id: request.id, code: "runtime_error", message: error.localizedDescription)
    }
  }

  /// What the engine holds right now (set when a load commits).
  private func loadedModel() -> DaemonResponse.LoadedModel? {
    engine.loadedModel.map { DaemonResponse.LoadedModel(path: $0.path, version: $0.version) }
  }

  private func resolveModelRequest(_ request: DaemonRequest) throws -> (URL, String) {
    guard let modelPath = request.modelPath, !modelPath.isEmpty else {
      throw DaemonServiceError.modelPathMissing
    }

    let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw DaemonServiceError.modelPathInvalid(modelURL.path)
    }

    return (modelURL, request.modelVersion ?? "v3")
  }
}
