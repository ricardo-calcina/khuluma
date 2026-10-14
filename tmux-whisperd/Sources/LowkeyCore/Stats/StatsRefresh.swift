import Foundation

/// When the stats window reloads: at most one load running and one pending,
/// results from a closed window's load dropped, and ledger-change bursts
/// debounced without ever postponing a reload indefinitely.
public struct StatsRefresh: Sendable {
  public static let debounce: TimeInterval = 0.3
  public static let maxDelay: TimeInterval = 2

  /// Bumped when the window closes, so a load still running is ignored.
  public private(set) var generation = 0
  public private(set) var running = false
  public private(set) var pending = false
  /// When the current burst of change events began (for `maxDelay`).
  private var burstStart: TimeInterval?

  public init() {}

  /// A reload is wanted. Returns the generation to load for, or nil if one is
  /// already running (it reloads again when that finishes).
  public mutating func request() -> Int? {
    burstStart = nil
    if running {
      pending = true
      return nil
    }
    running = true
    return generation
  }

  /// A load for `generation` finished. Returns whether to show its result,
  /// and the generation to load again for (a request came in meanwhile).
  public mutating func finished(generation loaded: Int) -> (show: Bool, again: Int?) {
    running = false
    let show = loaded == generation
    guard pending else { return (show, nil) }
    pending = false
    running = true
    return (show, generation)
  }

  /// The window closed: drop what's running and anything queued.
  public mutating func invalidate() {
    generation += 1
    pending = false
    running = false
    burstStart = nil
  }

  /// A ledger change event at `now`: how long to wait before reloading.
  /// Each event restarts the short debounce, but never past `maxDelay` from
  /// the first event of the burst.
  public mutating func delayForChange(at now: TimeInterval) -> TimeInterval {
    let start = burstStart ?? now
    burstStart = start
    return max(0, min(Self.debounce, start + Self.maxDelay - now))
  }
}
