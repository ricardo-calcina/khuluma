import Foundation

/// Keeps the app's own Parakeet daemon warm: probes the socket, and when the
/// daemon isn't ready makes sure the bundled `khulumad` runs (DaemonProcess)
/// and sends it the `warmup` op for the configured model. No CLI involved.
///
/// Event-driven, no background polling: launch, wake, recording start and a
/// native take finding the daemon unreachable. At most one check runs at a
/// time (later triggers are dropped while one is in flight), and failures
/// back off 30 s → 2 min → 10 min. While the daemon is starting or restarting
/// (`warming`), it rechecks every 30 s for up to 10 minutes.
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
    case restarted = "daemon restarted"
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

    /// From the app's settings (model path, the app's own socket), or nil
    /// when there is nothing to keep warm: cloud transcription, or no model
    /// yet (still downloading).
    public init?(config: AppConfig) {
      guard config.supervisionBlocker == nil, let modelPath = config.transcription.modelPath else { return nil }
      self.init(socketPath: config.transcription.socketPath, modelPath: modelPath,
                modelVersion: config.transcription.modelVersion ?? "v3")
    }
  }

  /// The outside world, injectable for tests.
  public struct Environment: Sendable {
    /// One bounded ping.
    public var probe: @Sendable (_ socketPath: String, _ timeout: TimeInterval) -> DaemonStatus?
    /// Starts the app's daemon if needed and loads the target's model.
    public var warmup: @Sendable (Target) throws -> WarmupReport
    public var now: @Sendable () -> Date
    /// Runs `work` after `delay` seconds (rechecks while warming).
    public var schedule: @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void
    /// Called before every probe so a daemon that already answers (warm,
    /// maybe one we didn't start) is still adopted and watched
    /// (`DaemonProcess.ensureRunning`, idempotent).
    public var adopt: @Sendable () -> Void = {}

    public init(
      probe: @escaping @Sendable (String, TimeInterval) -> DaemonStatus?,
      warmup: @escaping @Sendable (Target) throws -> WarmupReport,
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
  /// One scheduled recheck at most, however many triggers see "warming".
  private var recheckPending = false
  /// A settings change arrived during a check: check again once it ends
  /// (that check's result is dropped as stale).
  private var settingsPending = false
  /// The daemon was restarted during a check: warm it once that check ends.
  private var restartPending = false
  /// Bumped by `configure`: results of a check started before a change
  /// are dropped.
  private var configuration = 0
  /// Called on the supervision queue with the new state and a log line.
  private let onChange: @Sendable (State, String) -> Void

  public init(environment: Environment, queue: DispatchQueue = DispatchQueue(label: "khuluma.supervisor", qos: .utility),
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
      configuration += 1
      failures = 0
      retryAt = nil
      rechecks = 0
      state = .unknown
    }
  }

  /// Checks (and if needed warms) the daemon in the background, unless a
  /// check is already running.
  public func trigger(_ trigger: Trigger) {
    let start = lock.withLock { () -> Bool in
      if trigger == .restarted {
        // A fresh daemon: the old one's failures and backoff don't apply.
        failures = 0
        retryAt = nil
      }
      guard target != nil, !inFlight else {
        if trigger == .restarted, target != nil { restartPending = true }
        // A dropped recheck must not leave the next one blocked.
        if trigger == .recheck { recheckPending = false }
        if trigger == .settings, target != nil { settingsPending = true }
        return false
      }
      inFlight = true
      return true
    }
    guard start else { return }
    queue.async { [self] in
      run(trigger)
      let (settings, restarted) = lock.withLock { () -> (Bool, Bool) in
        inFlight = false
        defer { settingsPending = false; restartPending = false }
        return (settingsPending, restartPending)
      }
      if restarted { self.trigger(.restarted) } else if settings { self.trigger(.settings) }
    }
  }

  /// One check, synchronously (the queue's body; tests call it directly).
  func run(_ trigger: Trigger) {
    guard let (target, configuration) = lock.withLock({ () -> (Target, Int)? in
      if trigger == .recheck { recheckPending = false }
      return self.target.map { ($0, self.configuration) }
    }) else { return }

    environment.adopt()
    if let status = probe(target) {
      settle(configuration) {
        failures = 0
        retryAt = nil
        rechecks = 0
      }
      update(.ready(generation: status.generation), "daemon ready (\(trigger.rawValue))", configuration)
      return
    }

    if let retryAt = lock.withLock({ self.retryAt }), environment.now() < retryAt {
      // Backing off: keep the last state (a take that can't reach the
      // daemon is kept and retried).
      return
    }

    let report: WarmupReport
    do {
      report = try environment.warmup(target)
    } catch {
      fail("warmup failed: \(error.localizedDescription)", trigger: trigger, configuration: configuration)
      return
    }
    switch report.state {
    case .ready:
      // Confirm the daemon on our socket holds *our* model.
      guard let status = probe(target) else {
        warming("the daemon doesn't report the configured model yet", trigger: trigger, configuration: configuration)
        return
      }
      settle(configuration) {
        failures = 0
        retryAt = nil
        rechecks = 0
      }
      let took = report.durationMs.map { " in \($0)ms" } ?? ""
      update(.ready(generation: status.generation), "daemon warmed\(took) (\(trigger.rawValue))", configuration)
    case .warming:
      warming(report.message ?? report.reason ?? "warming", trigger: trigger, configuration: configuration)
    case .unavailable:
      fail(report.message ?? report.reason ?? "unavailable", trigger: trigger, configuration: configuration)
    }
  }

  /// The daemon's status when it holds the target's model, else nil.
  private func probe(_ target: Target) -> DaemonStatus? {
    guard let status = environment.probe(target.socketPath, Self.probeTimeout),
          status.holds(path: target.modelPath, version: target.modelVersion) else { return nil }
    return status
  }

  private func warming(_ reason: String, trigger: Trigger, configuration: Int) {
    let recheck = settle(configuration) { () -> Bool in
      retryAt = nil
      guard !recheckPending, rechecks < Self.maxRechecks else { return false }
      rechecks += 1
      recheckPending = true
      return true
    } ?? false
    update(.warming(reason), "daemon warming: \(reason) (\(trigger.rawValue))", configuration)
    if recheck {
      environment.schedule(Self.recheckDelay) { [weak self] in self?.trigger(.recheck) }
    }
  }

  private func fail(_ reason: String, trigger: Trigger, configuration: Int) {
    // From now, not from when the check began: a slow failure must not
    // use up its own backoff.
    let now = environment.now()
    guard let delay = settle(configuration, { () -> TimeInterval in
      failures += 1
      rechecks = 0
      let delay = Self.backoff[min(failures, Self.backoff.count) - 1]
      retryAt = now.addingTimeInterval(delay)
      return delay
    }) else { return }
    update(.unavailable(reason), "daemon unavailable: \(reason) (\(trigger.rawValue)); next try in \(Int(delay))s or later",
           configuration)
  }

  /// Runs `body` under the lock unless the configuration changed since the
  /// check began (then the result is stale and nil is returned).
  @discardableResult
  private func settle<T>(_ configuration: Int, _ body: () -> T) -> T? {
    lock.withLock { self.configuration == configuration ? body() : nil }
  }

  private func update(_ new: State, _ line: String, _ configuration: Int) {
    let changed = lock.withLock { () -> Bool? in
      guard self.configuration == configuration else { return nil }
      defer { state = new }
      return state != new
    }
    guard let changed else { return }
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

extension DaemonSupervisor {
  /// Warmup through the app's own daemon: ensure `process` runs it, wait
  /// briefly for the socket, then send `warmup` with the target's model.
  public static func ownedWarmup(
    process: DaemonProcess,
    answers: @escaping @Sendable (String) -> Bool = { DaemonClient(socketPath: $0).status(timeout: 0.25) != nil },
    warm: @escaping @Sendable (Target) throws -> Int? = { target in
      try DaemonClient(socketPath: target.socketPath)
        .warmup(modelPath: target.modelPath, modelVersion: target.modelVersion, timeout: 300)
    },
    startupWait: TimeInterval = 10,
    sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> @Sendable (Target) throws -> WarmupReport {
    { target in
      switch process.ensureRunning() {
      case .unavailable(let reason):
        return WarmupReport(state: .unavailable, reason: "daemon", message: reason)
      case .restarting:
        return WarmupReport(state: .warming, reason: "restarting", message: "the daemon is restarting")
      case .running, .external:
        break
      }
      var waited: TimeInterval = 0
      while !answers(target.socketPath) {
        guard waited < startupWait else {
          return WarmupReport(state: .warming, reason: "starting", message: "the daemon is starting")
        }
        sleep(0.2)
        waited += 0.2
      }
      do {
        let took = try warm(target)
        return WarmupReport(state: .ready, durationMs: took)
      } catch DaemonClient.ClientError.daemon(let code, let message) {
        return WarmupReport(state: .unavailable, reason: code, message: message)
      } catch DaemonClient.ClientError.timedOut {
        return WarmupReport(state: .warming, reason: "loading", message: "the model is still loading")
      }
    }
  }
}
