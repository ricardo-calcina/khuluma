import Foundation

/// Tells "the daemon or its model isn't ready yet" apart from real
/// transcription failures. A not-ready take is saved to recovered/ (durable)
/// and transcribed once the supervisor reports the daemon ready, instead of
/// the one-hour Retry list.
public enum DaemonReadiness {
  /// The reason when `error` came from a daemon that wasn't ready, else nil.
  /// `statusAfter` is asked (once, bounded) only for a timeout: a timed-out
  /// take whose daemon doesn't answer, or doesn't hold the model yet (a
  /// cold load longer than the take's timeout), wasn't the daemon's fault.
  public static func notReadyReason(_ error: Error, modelPath: String, modelVersion: String,
                                    statusAfter: () -> DaemonStatus?) -> String? {
    switch error as? DaemonClient.ClientError {
    case .unreachable?:
      return "daemon not running yet"
    case .timedOut?:
      guard let status = statusAfter() else { return "daemon not answering" }
      return status.holds(path: modelPath, version: modelVersion) ? nil : "speech model still loading"
    default:
      return nil
    }
  }
}

/// What to do once a not-ready take is safely in recovered/. The supervisor
/// may have gone ready while it was being saved (that ready notification
/// found nothing to recover, and identical ready states aren't repeated),
/// and the take's settings may predate a finished model download.
public enum KeptTakeFollowUp: Equatable, Sendable {
  /// Settings changed (e.g. the model arrived): apply them, which
  /// re-resolves supervision and runs recovery.
  case applySettings
  /// Ready now: recover it now.
  case recoverNow
  /// Not ready: the next ready notification recovers it.
  case waitForReady

  public static func decide(settingsChanged: Bool, supervisorReady: Bool) -> Self {
    if settingsChanged { return .applySettings }
    return supervisorReady ? .recoverNow : .waitForReady
  }
}
