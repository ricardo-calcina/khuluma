import Foundation

/// Keeps the Parakeet daemon warm for Lowkey without owning it: probes the
/// socket, and when the daemon isn't ready asks the CLI (`warmup --json`,
/// which starts it under the CLI's lifecycle lock and loads the model).
///
/// Event-driven, no background polling: launch, wake, recording start and a
/// native take finding the daemon unreachable. At most one check runs at a
/// time (later triggers are dropped while one is in flight), and failures
/// back off 30 s → 2 min → 10 min. While the CLI reports `warming` (a build
/// or another caller's start), it rechecks every 30 s for up to 10 minutes.
public final class DaemonSupervisor: @unchecked Sendable {
  public enum State: Equatable, Sendable {
    case unknown
    /// The daemon holds our model (generation identifies the process).
    case ready(generation: String?)
    case warming(String)
    case unavailable(String)
  }

  public enum Trigger: String, Sendable {
    case launch, wake, settings, recheck
    case recordingStart = "recording start"
    case unreachable = "daemon unreachable"
  }

  /// The daemon and model to keep warm.
  public struct Target: Equatable, Sendable {
    public let socketPath: String
    public let modelPath: String
    public let modelVersion: String

    public init(socketPath: String, modelPath: String, modelVersion: String) {
      self.socketPath = socketPath
      self.modelPath = modelPath
      self.modelVersion = modelVersion
    }

    /// From app-config, or nil when supervision must stay off.
    public init?(config: AppConfig) {
      guard config.supervisionBlocker == nil, let transcription = config.transcription,
            let modelPath = transcription.modelPath else { return nil }
      self.init(socketPath: transcription.socketPath, modelPath: modelPath,
                modelVersion: transcription.modelVersion ?? "v3")
    }
  }

  /// The outside world, injectable for tests.
  public struct Environment: Sendable {
    /// One bounded ping.
    public var probe: @Sendable (_ socketPath: String, _ timeout: TimeInterval) -> DaemonStatus?
    /// `tmux-whisper warmup --json`.
    public var warmup: @Sendable () throws -> WarmupReport
    public var now: @Sendable () -> Date
    /// Runs `work` after `delay` seconds (rechecks while warming).
    public var schedule: @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    public init(
      probe: @escaping @Sendable (String, TimeInterval) -> DaemonStatus?,
      warmup: @escaping @Sendable () throws -> WarmupReport,
      now: @escaping @Sendable () -> Date = { Date() },
      schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    ) {
      self.probe = probe
      self.warmup = warmup
      self.now = now
      self.schedule = schedule
    }
  }

  public static let probeTimeout: TimeInterval = 0.25
  public static let backoff: [TimeInterval] = [30, 120, 600]
  public static let recheckDelay: TimeInterval = 30
  public static let maxRechecks = 20

  private let environment: Environment
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var target: Target?
  private var state: State = .unknown
  private var inFlight = false
  private var failures = 0
  private var retryAt: Date?
  private var rechecks = 0
  /// Called on the supervision queue with the new state and a log line.
  private let onChange: @Sendable (State, String) -> Void

  public init(environment: Environment, queue: DispatchQueue = DispatchQueue(label: "lowkey.supervisor", qos: .utility),
              onChange: @escaping @Sendable (State, String) -> Void) {
    self.environment = environment
    self.queue = queue
    self.onChange = onChange
  }

  public var currentState: State {
    lock.withLock { state }
  }

  /// Sets what to keep warm; nil turns supervision off. A new target resets
  /// the backoff.
  public func configure(_ target: Target?) {
    lock.withLock {
      guard target != self.target else { return }
      self.target = target
      failures = 0
      retryAt = nil
      rechecks = 0
      if target == nil { state = .unknown }
    }
  }

  /// Checks (and if needed warms) the daemon in the background, unless a
  /// check is already running.
  public func trigger(_ trigger: Trigger) {
    let start = lock.withLock { () -> Bool in
      guard target != nil, !inFlight else { return false }
      inFlight = true
      return true
    }
    guard start else { return }
    queue.async { [self] in
      run(trigger)
      lock.withLock { inFlight = false }
    }
  }

  /// One check, synchronously (the queue's body; tests call it directly).
  func run(_ trigger: Trigger) {
    guard let target = lock.withLock({ self.target }) else { return }
    if trigger != .recheck { lock.withLock { rechecks = 0 } }

    if let status = environment.probe(target.socketPath, Self.probeTimeout),
       status.holds(path: target.modelPath, version: target.modelVersion) {
      lock.withLock {
        failures = 0
        retryAt = nil
      }
      update(.ready(generation: status.generation), "daemon ready (\(trigger.rawValue))")
      return
    }

    let now = environment.now()
    if let retryAt = lock.withLock({ self.retryAt }), now < retryAt {
      // Backing off: keep the last state (the take falls back to the CLI,
      // which starts the daemon itself if it can).
      return
    }

    let report: WarmupReport
    do {
      report = try environment.warmup()
    } catch {
      fail("warmup failed: \(error.localizedDescription)", trigger: trigger, now: now)
      return
    }
    switch report.state {
    case .ready:
      lock.withLock {
        failures = 0
        retryAt = nil
      }
      let took = report.durationMs.map { " in \($0)ms" } ?? ""
      update(.ready(generation: report.generation), "daemon warmed\(took) (\(trigger.rawValue))")
    case .warming:
      let reason = report.message ?? report.reason ?? "warming"
      let recheck = lock.withLock { () -> Bool in
        retryAt = nil
        guard rechecks < Self.maxRechecks else { return false }
        rechecks += 1
        return true
      }
      update(.warming(reason), "daemon warming: \(reason) (\(trigger.rawValue))")
      if recheck {
        environment.schedule(Self.recheckDelay) { [weak self] in self?.trigger(.recheck) }
      }
    case .unavailable:
      fail(report.message ?? report.reason ?? "unavailable", trigger: trigger, now: now)
    }
  }

  private func fail(_ reason: String, trigger: Trigger, now: Date) {
    let delay = lock.withLock { () -> TimeInterval in
      failures += 1
      let delay = Self.backoff[min(failures, Self.backoff.count) - 1]
      retryAt = now.addingTimeInterval(delay)
      return delay
    }
    update(.unavailable(reason), "daemon unavailable: \(reason) (\(trigger.rawValue)); next try in \(Int(delay))s or later")
  }

  private func update(_ new: State, _ line: String) {
    let changed = lock.withLock { () -> Bool in
      defer { state = new }
      return state != new
    }
    // Repeated "ready" checks stay quiet; anything else is worth a line.
    if changed || !(new.isReady) { onChange(new, line) }
  }
}

extension DaemonSupervisor.State {
  public var isReady: Bool {
    if case .ready = self { return true }
    return false
  }
}
