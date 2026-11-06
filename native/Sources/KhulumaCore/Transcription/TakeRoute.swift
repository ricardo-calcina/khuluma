import Foundation

/// Why a take was kept rather than transcribed: `reason` for the menu and
/// log, `category` a fixed code for the take log.
public struct KeptTake: Equatable, Sendable {
  public let reason: String
  public let category: String

  public init(reason: String, category: String) {
    self.reason = reason
    self.category = category
  }

  /// A native transcription failure that isn't "not ready" or a timeout
  /// (those have their own paths): the take is kept in recovered/ and
  /// retried when the supervisor next reports ready, on a settings change
  /// or at the next launch. Never the error's message, which could carry
  /// daemon output.
  public static func afterNativeFailure(_ error: Error) -> KeptTake {
    switch error as? DaemonClient.ClientError {
    case .unreachable?: return KeptTake(reason: "transcription failed (daemon unreachable)", category: "daemon_unreachable")
    case .protocolError?: return KeptTake(reason: "transcription failed (daemon protocol error)", category: "daemon_protocol")
    case .daemon(let code, _)?: return KeptTake(reason: "transcription failed (daemon error \(code))", category: "daemon_error")
    case .timedOut?: return KeptTake(reason: "transcription failed (daemon timed out)", category: "daemon_timed_out")
    case nil: return KeptTake(reason: "transcription failed", category: "transcription_failed")
    }
  }
}

/// Where a stopped take goes. Every take is transcribed by the app itself
/// (Parakeet through its daemon, or ElevenLabs Scribe) or kept: there is no
/// other route.
public enum TakeRoute: Equatable, Sendable {
  case scribe
  case native
  /// Saved to recovered/ and transcribed into history once it can be.
  case keep(KeptTake)

  /// `config` is the settings read for the take, nil when they weren't
  /// read (`problem` says why).
  public static func decide(config: AppConfig?, problem: String? = nil) -> TakeRoute {
    guard let config else {
      return .keep(KeptTake(reason: problem ?? "settings unavailable", category: "settings_unavailable"))
    }
    if config.scribe != nil { return .scribe }
    if let blocker = config.nativePipelineBlocker {
      return .keep(KeptTake(reason: blocker,
                            category: blocker == TranscriptionSettings.modelMissing ? "model_missing" : "not_supported"))
    }
    guard config.native != nil else {
      return .keep(KeptTake(reason: "transcription settings missing", category: "settings_missing"))
    }
    return .native
  }
}
