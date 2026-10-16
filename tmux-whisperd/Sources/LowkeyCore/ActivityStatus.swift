import Foundation

/// What the menu-bar icon and status line show: a recording, takes being
/// processed, or the last error. The controller drives it; kept here so its
/// transitions are testable without AppKit.
public struct ActivityStatus: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case ready, recording, processing, error(String)
  }

  public private(set) var phase: Phase = .ready
  /// Takes (and retries) handed to processing that haven't finished yet.
  public private(set) var processing = 0

  public init() {}

  public mutating func recordingStarted() {
    phase = .recording
  }

  /// A take (or a retry) went to processing.
  public mutating func processingStarted() {
    processing += 1
    phase = .processing
  }

  /// The recording was discarded: back to whatever else is going on.
  public mutating func recordingCancelled() {
    phase = processing > 0 ? .processing : .ready
  }

  /// A take handed to processing is done. An error stays on screen until
  /// something else replaces it; otherwise a recording started since wins.
  public mutating func processingFinished(error: String?, recording: Bool) {
    processing = max(0, processing - 1)
    if let error {
      phase = .error(error)
    } else if recording {
      phase = .recording
    } else {
      phase = processing > 0 ? .processing : .ready
    }
  }

  public mutating func failed(_ message: String) {
    phase = .error(message)
  }

  /// Settings that apply cleanly clear a shown error. Returns whether there
  /// was one.
  @discardableResult
  public mutating func clearError() -> Bool {
    guard case .error = phase else { return false }
    phase = processing > 0 ? .processing : .ready
    return true
  }

  /// SF Symbol for the menu-bar icon.
  public var symbol: String {
    switch phase {
    case .ready: return "mic"
    case .recording: return "mic.fill"
    case .processing: return "waveform"
    case .error: return "exclamationmark.triangle"
    }
  }

  /// The menu's first line.
  public var title: String {
    switch phase {
    case .ready: return "Ready"
    case .recording: return "Recording…"
    case .processing: return processing > 1 ? "Processing (\(processing))…" : "Processing…"
    case .error(let message): return "Error: \(message)"
    }
  }
}
