import Foundation

/// How a take ended, for the controller to show (sound, status line).
public enum TakeResult: Equatable, Sendable {
  /// `recorded`: its record is spooled (or the CLI saved it to history).
  case delivered(recorded: Bool)
  case noSpeech
  case failed(String)
  /// Transcription timed out; `kept` says whether the audio was kept for Retry.
  case timedOut(String, kept: Bool)

  /// Whether the take no longer needs its audio: its text was delivered
  /// and recorded, it had no speech, or Retry keeps the recording. Any
  /// other ending leaves a copy saved at Quit for the next launch to recover.
  public var settlesAudio: Bool {
    switch self {
    case .delivered(let recorded): return recorded
    case .noSpeech: return true
    case .failed: return false
    case .timedOut(_, let kept): return kept
    }
  }
}
