import Foundation
import Testing
@testable import LowkeyCore

/// A scripted world for DaemonSupervisor: probe answers, warmup reports,
/// a settable clock and captured rechecks.
private final class World: @unchecked Sendable {
  let lock = NSLock()
  var status: DaemonStatus?
  var reports: [Result<WarmupReport, Error>] = []
  var warmups = 0
  var now = Date(timeIntervalSince1970: 1_000_000)
  var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
  var lines: [String] = []
  var states: [DaemonSupervisor.State] = []
  /// Blocks warmup until signalled (single-flight test).
  var gate: DispatchSemaphore?
  /// Runs inside warmup (e.g. to change settings or the clock meanwhile).
  var duringWarmup: (() -> Void)?

  func environment() -> DaemonSupervisor.Environment {
    DaemonSupervisor.Environment(
      probe: { _, _ in self.lock.withLock { self.status } },
      warmup: {
        self.gate?.wait()
        self.duringWarmup?()
        return try self.lock.withLock { () -> Result<WarmupReport, Error> in
          self.warmups += 1
          return self.reports.isEmpty ? .success(WarmupReport(state: .ready)) : self.reports.removeFirst()
        }.get()
      },
      now: { self.lock.withLock { self.now } },
      schedule: { delay, work in self.lock.withLock { self.scheduled.append((delay, work)) } })
  }

  func supervisor(queue: DispatchQueue = DispatchQueue(label: "test.supervisor")) -> DaemonSupervisor {
    DaemonSupervisor(environment: environment(), queue: queue) { state, line in
      self.lock.withLock {
        self.states.append(state)
        self.lines.append(line)
      }
    }
  }

  func advance(_ seconds: TimeInterval) { lock.withLock { now = now.addingTimeInterval(seconds) } }
}

private let target = DaemonSupervisor.Target(socketPath: "/s.sock", modelPath: "/m", modelVersion: "v3")
private struct Boom: Error, LocalizedError { var errorDescription: String? { "CLI exited 1" } }

struct DaemonSupervisorTests {
  @Test func aWarmDaemonNeedsNoCLI() {
    let world = World()
    world.status = DaemonStatus(version: "0.3.0", generation: "g1", modelLoaded: .init(path: "/m", version: "v3"))
    let supervisor = world.supervisor()
    supervisor.configure(target)
    supervisor.run(.launch)
    #expect(world.warmups == 0)
    #expect(supervisor.currentState == .ready(generation: "g1"))
    // Repeated ready checks stay out of the log.
    supervisor.run(.recordingStart)
    #expect(world.lines.count == 1)
  }

  @Test func aColdOrOtherModelDaemonIsWarmedThroughTheCLI() {
    let world = World()
    world.status = DaemonStatus(version: "0.3.0", generation: "g1", modelLoaded: .init(path: "/m", version: "v2"))
    world.reports = [.success(WarmupReport(state: .ready, generation: "g1", durationMs: 812))]
    let warm = DaemonStatus(version: "0.3.0", generation: "g1", modelLoaded: .init(path: "/m", version: "v3"))
    world.duringWarmup = { world.status = warm }
    let supervisor = world.supervisor()
    supervisor.configure(target)
    supervisor.run(.wake)
    #expect(world.warmups == 1)
    #expect(supervisor.currentState == .ready(generation: "g1"))
    #expect(world.lines.last == "daemon warmed in 812ms (wake)")
    // No daemon at all: same path.
    world.duringWarmup = nil
    world.status = nil
    supervisor.run(.unreachable)
    #expect(world.warmups == 2)
    // "ready" from a CLI that warmed some other model isn't ready for us.
    #expect(supervisor.currentState == .warming("the daemon doesn't report the configured model yet"))
  }

  @Test func failuresBackOffAndSuccessResets() {
    let world = World()
    world.reports = [.success(WarmupReport(state: .unavailable, reason: "no_model", message: "no model")),
                     .failure(Boom()), .success(WarmupReport(state: .unavailable, reason: "x")),
                     .success(WarmupReport(state: .unavailable, reason: "y"))]
    let supervisor = world.supervisor()
    supervisor.configure(target)
    supervisor.run(.launch)
    #expect(supervisor.currentState == .unavailable("no model"))
    #expect(world.lines.last?.hasSuffix("next try in 30s or later") == true)
    supervisor.run(.recordingStart)
    #expect(world.warmups == 1, "backing off")
    world.advance(30)
    supervisor.run(.recordingStart)
    #expect(world.warmups == 2)
    #expect(supervisor.currentState == .unavailable("warmup failed: CLI exited 1"))
    world.advance(119)
    supervisor.run(.wake)
    #expect(world.warmups == 2, "second failure waits 2 min")
    world.advance(1)
    supervisor.run(.wake)
    #expect(world.warmups == 3)
    world.advance(600)
    supervisor.run(.wake)
    #expect(world.warmups == 4)
    #expect(world.lines.last?.hasSuffix("next try in 600s or later") == true, "capped at 10 min")
    // A daemon that turns up warm (e.g. started by a CLI fallback) clears it.
    world.status = DaemonStatus(version: "0.3.0", generation: "g2", modelLoaded: .init(path: "/m", version: "v3"))
    supervisor.run(.recordingStart)
    #expect(supervisor.currentState == .ready(generation: "g2"))
    world.status = nil
    world.reports = [.success(WarmupReport(state: .unavailable, reason: "z"))]
    supervisor.run(.recordingStart)
    #expect(world.warmups == 5, "no backoff left over after success")
    #expect(world.lines.last?.hasSuffix("next try in 30s or later") == true)
  }

  @Test func warmingRechecksForABoundedTime() {
    let world = World()
    world.reports = Array(repeating: .success(WarmupReport(state: .warming, reason: "building", message: "building tmux-whisperd")),
                          count: 40)
    let supervisor = world.supervisor()
    supervisor.configure(target)
    supervisor.run(.launch)
    #expect(supervisor.currentState == .warming("building tmux-whisperd"))
    #expect(world.scheduled.count == 1 && world.scheduled[0].0 == DaemonSupervisor.recheckDelay)
    // More takes during the build don't start more recheck chains.
    supervisor.run(.recordingStart)
    supervisor.run(.wake)
    #expect(world.scheduled.count == 1)
    for _ in 0..<25 { supervisor.run(.recheck) }
    #expect(world.scheduled.count == DaemonSupervisor.maxRechecks, "stops rechecking after 10 minutes")
    supervisor.run(.recordingStart)
    #expect(world.scheduled.count == DaemonSupervisor.maxRechecks, "the budget resets only after ready or a failure")
  }

  @Test func aCheckStartedBeforeASettingsChangeIsDropped() {
    let world = World()
    let supervisor = world.supervisor()
    supervisor.configure(target)
    world.reports = [.success(WarmupReport(state: .unavailable, reason: "x", message: "old model missing"))]
    world.duringWarmup = {
      supervisor.configure(DaemonSupervisor.Target(socketPath: "/s.sock", modelPath: "/other", modelVersion: "v3"))
    }
    supervisor.run(.launch)
    #expect(supervisor.currentState == .unknown)
    #expect(world.lines.isEmpty)
    // ...and leaves no backoff behind for the new target.
    world.duringWarmup = nil
    supervisor.run(.settings)
    #expect(world.warmups == 2)
  }

  @Test func aSettingsChangeDuringACheckIsCheckedAfterIt() {
    let world = World()
    let queue = DispatchQueue(label: "test.supervisor.settings")
    let supervisor = world.supervisor(queue: queue)
    supervisor.configure(target)
    world.reports = [.success(WarmupReport(state: .unavailable, reason: "x", message: "stale")),
                     .success(WarmupReport(state: .unavailable, reason: "y", message: "fresh"))]
    let other = DaemonSupervisor.Target(socketPath: "/s.sock", modelPath: "/other", modelVersion: "v3")
    world.duringWarmup = {
      world.duringWarmup = nil
      supervisor.configure(other)
      supervisor.trigger(.settings) // dropped: the launch check is still running
    }
    supervisor.trigger(.launch)
    queue.sync {}
    queue.sync {}
    // The launch result was stale; the settings check ran after it.
    #expect(world.warmups == 2)
    #expect(supervisor.currentState == .unavailable("fresh"))
  }

  @Test func backoffCountsFromWhenAFailureFinished() {
    let world = World()
    world.reports = [.failure(Boom()), .success(WarmupReport(state: .unavailable, reason: "x"))]
    world.duringWarmup = { world.advance(120) } // a CLI that took 2 minutes to fail
    let supervisor = world.supervisor()
    supervisor.configure(target)
    supervisor.run(.launch)
    world.duringWarmup = nil
    world.advance(29)
    supervisor.run(.recordingStart)
    #expect(world.warmups == 1, "still within 30 s of the failure")
    world.advance(1)
    supervisor.run(.recordingStart)
    #expect(world.warmups == 2)
  }

  @Test func oneCheckAtATimeAndOffWhenUnconfigured() async throws {
    let world = World()
    world.gate = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "test.supervisor.async")
    let supervisor = world.supervisor(queue: queue)
    supervisor.trigger(.launch)
    queue.sync {}
    #expect(world.warmups == 0, "no target: nothing runs")

    supervisor.configure(target)
    world.duringWarmup = { world.status = DaemonStatus(version: "0.3.0", modelLoaded: .init(path: "/m", version: "v3")) }
    supervisor.trigger(.launch)
    supervisor.trigger(.wake)
    supervisor.trigger(.recordingStart)
    world.gate?.signal()
    world.gate?.signal()
    world.gate?.signal()
    queue.sync {}
    #expect(world.warmups == 1, "triggers during a check are dropped")
    #expect(supervisor.currentState == .ready(generation: nil))

    supervisor.configure(nil)
    #expect(supervisor.currentState == .unknown)
  }

  @Test func supervisionNeedsANewEnoughCLIAndTheSwitch() throws {
    func config(capabilities: String, supervise: String, modelPath: String = #""/m""#) throws -> AppConfig {
      let json = #"""
      {"schema_version":1,"cli_version":"0.11.0-dev","hotkey":"ctrl+option+space","sounds":{},
       "inline":{"autosend":true,"send_mode":"enter","paste_target":"current","process_sound":true,"activate_delay_ms":0,"send_delay_ms":0},
       "transcription":{"socket_path":"/s.sock","model_path":MODEL,"model_version":"v3","model_label":"m","language":"en",
         "tail_pad_ms":"500","tail_rescue":true,"tail_rescue_ms":"","tail_rescue_min_ms":"","chunking":false,
         "silence_trim":false,"keep_logs":false,"ffmpeg":true,"timeout_seconds":"600","processing_dir":"/p"},
       "pipeline":{"native":true,"verify":true SUPERVISE}CAPS}
      """#.replacingOccurrences(of: "SUPERVISE", with: supervise)
        .replacingOccurrences(of: "CAPS", with: capabilities)
        .replacingOccurrences(of: "MODEL", with: modelPath)
      return try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }
    let all = #","capabilities":["take_markers","lifecycle_lock","warmup_json"]"#
    let ok = try config(capabilities: all, supervise: #","supervise":true"#)
    #expect(ok.supervisionBlocker == nil)
    #expect(DaemonSupervisor.Target(config: ok) == target)
    #expect(try config(capabilities: "", supervise: "").supervisionBlocker == "CLI too old for daemon supervision")
    #expect(try config(capabilities: #","capabilities":["take_markers"]"#, supervise: #","supervise":true"#)
      .supervisionBlocker == "CLI too old for daemon supervision")
    let off = try config(capabilities: all, supervise: #","supervise":false"#)
    #expect(off.supervisionBlocker == "[app] supervise_daemon = false")
    #expect(DaemonSupervisor.Target(config: off) == nil)
    #expect(try config(capabilities: all, supervise: #","supervise":true"#, modelPath: "null")
      .supervisionBlocker == "no Parakeet model path")
  }

  @Test func decodesTheCLIsWarmupReport() throws {
    let json = #"{"state": "warming", "reason": "building", "message": "building tmux-whisperd", "socket_path": "/s", "model_path": "/m", "model_version": "v3", "daemon_version": null, "generation": null, "pid": null, "model_loaded": null, "duration_ms": null}"#
    let report = try JSONDecoder().decode(WarmupReport.self, from: Data(json.utf8))
    #expect(report == WarmupReport(state: .warming, reason: "building", message: "building tmux-whisperd"))
  }
}

struct TimedOutTakesTests {
  @Test func keepsTakesPrivatelyForAnHour() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "lk-timedout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TimedOutTakes(directory: dir)
    let saved = Date(timeIntervalSince1970: 2_000_000)
    let info = TimedOutTakes.Info(takeId: "t-1/..", app: "Claude", recordMs: 2000, startupMs: 110,
                                  startedAtMs: 1_999_998_000, savedAt: saved, generation: "g1")
    let entry = try store.save(samples: [0.5, -0.5, 0], info: info)
    #expect(entry.wav.lastPathComponent == "t-1.wav")
    let mode = try FileManager.default.attributesOfItem(atPath: entry.wav.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
    #expect(dirMode == 0o700)
    #expect(try RecoveredTakes.samples(at: entry.wav).count == 3)

    #expect(store.all(now: saved.addingTimeInterval(3599)) == [entry])
    // Orphaned audio is dropped; expired takes are deleted.
    try Data([1, 2]).write(to: dir.appendingPathComponent("orphan.wav"))
    #expect(store.all(now: saved.addingTimeInterval(3600)).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

    let again = try store.save(samples: [0.1], info: info)
    store.remove(again)
    #expect(store.all(now: saved).isEmpty)
  }
}
