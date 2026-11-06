import Foundation
import Testing
@testable import KhulumaCore

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
      warmup: { _ in
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
    world.reports = Array(repeating: .success(WarmupReport(state: .warming, reason: "building", message: "building khulumad")),
                          count: 40)
    let supervisor = world.supervisor()
    supervisor.configure(target)
    supervisor.run(.launch)
    #expect(supervisor.currentState == .warming("building khulumad"))
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

  @Test func supervisionNeedsAModelNotTheCLIEraSwitch() throws {
    func config(supervise: Bool, modelPath: String = #""/m""#) throws -> AppConfig {
      try AppConfigFixture.decode(AppConfigFixture.json
        .replacingOccurrences(of: #""pipeline":{"supervise":true}"#, with: #""pipeline":{"supervise":\#(supervise)}"#)
        .replacingOccurrences(of: #""model_path":"/m""#, with: #""model_path":\#(modelPath)"#))
    }
    let ok = try config(supervise: true)
    #expect(ok.supervisionBlocker == nil)
    #expect(DaemonSupervisor.Target(config: ok) == target)
    // The app owns its daemon and takes need it: the CLI-era switch no
    // longer turns supervision off.
    let off = try config(supervise: false)
    #expect(off.supervisionBlocker == nil)
    #expect(DaemonSupervisor.Target(config: off) == target)
    let noModel = try config(supervise: true, modelPath: "null")
    #expect(noModel.supervisionBlocker == "speech model still downloading")
    #expect(DaemonSupervisor.Target(config: noModel) == nil)
  }

  @Test func decodesTheCLIsWarmupReport() throws {
    let json = #"{"state": "warming", "reason": "building", "message": "building khulumad", "socket_path": "/s", "model_path": "/m", "model_version": "v3", "daemon_version": null, "generation": null, "pid": null, "model_loaded": null, "duration_ms": null}"#
    let report = try JSONDecoder().decode(WarmupReport.self, from: Data(json.utf8))
    #expect(report == WarmupReport(state: .warming, reason: "building", message: "building khulumad"))
  }
}

struct TimedOutTakesTests {
  private func stores() -> (TimedOutTakes, RecoveredTakes, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory() + "khuluma-timedout-\(UUID().uuidString)")
    let recovered = RecoveredTakes(directory: root.appendingPathComponent("recovered"))
    return (TimedOutTakes(directory: root.appendingPathComponent("timed-out"), recovered: recovered), recovered, root)
  }

  @Test func keepsTakesPrivatelyForAnHourThenHandsThemToRecovered() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = store.directory
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
    #expect(recovered.all().isEmpty)
    // Expired: handed to recovered/ under the same take id, not deleted.
    #expect(store.all(now: saved.addingTimeInterval(3600)).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    let handed = recovered.all()
    #expect(handed.count == 1)
    #expect(RecoveredTakes.takeId(of: handed[0]) == "t-1")
    #expect(try RecoveredTakes.samples(at: handed[0]).count == 3)
    let handedMode = try FileManager.default.attributesOfItem(atPath: handed[0].path)[.posixPermissions] as? Int
    #expect(handedMode == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: recovered.directory.path).count == 1)  // no temp left

    // Discard still deletes.
    let again = try store.save(samples: [0.1], info: info)
    store.remove(again)
    #expect(store.all(now: saved).isEmpty)
    #expect(recovered.all().count == 1)
  }

  @Test func brokenSidecarAudioGoesToRecoveredUnderAStableId() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = try store.save(samples: [0.25, 0.25], info: .init(takeId: "t-2", app: nil, recordMs: 1, startupMs: 0, startedAtMs: 0))
    try Data("{broken".utf8).write(to: entry.wav.deletingPathExtension().appendingPathExtension("json"))
    #expect(store.all().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    let handed = recovered.all()
    #expect(handed.count == 1)
    #expect(RecoveredTakes.takeId(of: handed[0]) == "timedout-t-2")
    #expect(try RecoveredTakes.samples(at: handed[0]).count == 2)
  }

  /// A crash after the recovered copy but before the source was removed:
  /// the next handoff recognises the copy instead of making a second take.
  @Test func aRepeatedHandoffDoesNotDuplicate() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let wav = WAVEncoder.encode(samples: [0.1, 0.2])
    try wav.write(to: store.directory.appendingPathComponent("orphan.wav"))
    try recovered.adopt(wav: wav, takeId: "timedout-orphan", at: Date(timeIntervalSince1970: 1))
    #expect(store.all().isEmpty)
    #expect(recovered.all().count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    // Different bytes under the same id are a different take: a distinct id,
    // so recording one never settles the other.
    try WAVEncoder.encode(samples: [0.9, 0.9, 0.9]).write(to: store.directory.appendingPathComponent("orphan.wav"))
    #expect(store.all().isEmpty)
    #expect(Set(recovered.all().map(RecoveredTakes.takeId(of:))) == ["timedout-orphan", "timedout-orphan-2"])
  }

  @Test func orphanAudioGoesToRecoveredAndEmptyAudioIsDropped() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try WAVEncoder.encode(samples: [0.1, 0.2, 0.3]).write(to: store.directory.appendingPathComponent("orphan.wav"))
    try Data([1, 2]).write(to: store.directory.appendingPathComponent("tiny.wav"))
    try Data("{}".utf8).write(to: store.directory.appendingPathComponent("lonely.json"))
    #expect(store.all().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    let handed = recovered.all()
    #expect(handed.count == 1)
    #expect(RecoveredTakes.takeId(of: handed[0]) == "timedout-orphan")
    #expect(try RecoveredTakes.samples(at: handed[0]).count == 3)
  }

  @Test func unreadableAudioIsNeverDeleted() throws {
    guard getuid() != 0 else { return }  // root reads anything
    let (store, recovered, root) = stores()
    defer {
      chmod(store.directory.appendingPathComponent("locked.wav").path, 0o600)
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let locked = store.directory.appendingPathComponent("locked.wav")
    try WAVEncoder.encode(samples: [0.4, 0.4]).write(to: locked)
    chmod(locked.path, 0o000)
    #expect(store.all().isEmpty)
    #expect(FileManager.default.fileExists(atPath: locked.path))
    #expect(recovered.all().isEmpty)
  }

  @Test func takesLeftInTheOldTempFolderMoveIntoTheStoreAsPairs() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = TimedOutTakes(directory: root.appendingPathComponent("old-tmp"), recovered: recovered)
    let later = Date().addingTimeInterval(3600)
    let info = TimedOutTakes.Info(takeId: "t-old", app: "Notes", recordMs: 900, startupMs: 50, startedAtMs: 1,
                                  savedAt: Date(timeIntervalSince1970: 2_000_000))
    try old.save(samples: [0.3, 0.3, 0.3], info: info)
    try WAVEncoder.encode(samples: [0.1]).write(to: old.directory.appendingPathComponent("orphan.wav"))
    // A pair whose WAV clashes here with different bytes: the whole pair
    // stays in the old folder (its sidecar isn't split off).
    let clash = TimedOutTakes.Info(takeId: "clash", app: nil, recordMs: 1, startupMs: 0, startedAtMs: 0,
                                   savedAt: Date(timeIntervalSince1970: 2_000_000))
    try old.save(samples: [0.7], info: clash)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("other".utf8).write(to: store.directory.appendingPathComponent("clash.wav"))

    #expect(store.adoptLegacy(from: old.directory, now: later) == 2)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: old.directory.path)) == ["clash.wav", "clash.json"])
    #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("clash.json").path))
    let listed = store.all(now: info.savedAt)
    #expect(listed.map(\.info) == [info])
    #expect(try RecoveredTakes.samples(at: listed[0].wav).count == 3)
    #expect(listed[0].wav.deletingLastPathComponent().path == store.directory.path)
    // The orphan came across and was handed to recovered/; the clashing
    // "other" (header-less, 5 bytes) was dropped as empty audio.
    #expect(recovered.all().count == 1)
    // Now the name is free: the pair moves, then the old folder is gone.
    #expect(store.adoptLegacy(from: old.directory, now: later) == 1)
    #expect(!FileManager.default.fileExists(atPath: old.directory.path))
    #expect(store.adoptLegacy(from: old.directory, now: later) == 0)
    #expect(store.adoptLegacy(from: root.appendingPathComponent("missing")) == 0)
  }

  /// Already identical here (a crash after copying, before removing): the
  /// old copies are removed, nothing doubles.
  @Test func anAlreadyCopiedPairIsJustRemovedFromTheOldFolder() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = TimedOutTakes(directory: root.appendingPathComponent("old-tmp"), recovered: recovered)
    let later = Date().addingTimeInterval(3600)
    let info = TimedOutTakes.Info(takeId: "t-same", app: nil, recordMs: 1, startupMs: 0, startedAtMs: 0,
                                  savedAt: Date(timeIntervalSince1970: 2_000_000))
    try old.save(samples: [0.2, 0.2], info: info)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    for name in ["t-same.wav", "t-same.json"] {
      try FileManager.default.copyItem(at: old.directory.appendingPathComponent(name), to: store.directory.appendingPathComponent(name))
    }
    #expect(store.adoptLegacy(from: old.directory, now: later) == 1)
    #expect(!FileManager.default.fileExists(atPath: old.directory.path))
    #expect(store.all(now: info.savedAt).map(\.info) == [info])
  }

  @Test func adoptionsInTheSameMillisecondNeverOverwrite() throws {
    let (_, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let at = Date(timeIntervalSince1970: 5)
    let a = try recovered.adopt(wav: WAVEncoder.encode(samples: [0.1]), takeId: "same", at: at)
    let b = try recovered.adopt(wav: WAVEncoder.encode(samples: [0.2]), takeId: "same", at: at)
    #expect(a != b)
    #expect(try RecoveredTakes.samples(at: a) != RecoveredTakes.samples(at: b))
    #expect(RecoveredTakes.takeId(of: b) == "same-2")
    #expect(try RecoveredTakes.samples(at: a).first.map { abs($0 - 0.1) < 0.001 } == true)
  }

  @Test func youngLegacyFilesWaitForALaterLaunch() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = TimedOutTakes(directory: root.appendingPathComponent("old-tmp"), recovered: recovered)
    try old.save(samples: [0.3], info: .init(takeId: "pair", app: nil, recordMs: 1, startupMs: 0, startedAtMs: 0))
    try WAVEncoder.encode(samples: [0.1]).write(to: old.directory.appendingPathComponent("lone.wav"))
    let written = Date()
    #expect(store.adoptLegacy(from: old.directory, now: written.addingTimeInterval(60)) == 0)
    #expect(store.adoptLegacy(from: old.directory, now: written.addingTimeInterval(180)) == 1, "the pair after 2 min")
    #expect(FileManager.default.fileExists(atPath: old.directory.appendingPathComponent("lone.wav").path))
    #expect(store.adoptLegacy(from: old.directory, now: written.addingTimeInterval(660)) == 1, "the orphan after 10 min")
  }

  /// A clash on the sidecar aborts before any audio is published, and no
  /// staged temp file is left or listed.
  @Test func aFailedMigrationNeverPublishesAudioAlone() throws {
    let (store, recovered, root) = stores()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = TimedOutTakes(directory: root.appendingPathComponent("old-tmp"), recovered: recovered)
    try old.save(samples: [0.3, 0.3], info: .init(takeId: "t", app: nil, recordMs: 1, startupMs: 0, startedAtMs: 0))
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("different".utf8).write(to: store.directory.appendingPathComponent("t.json"))
    #expect(store.adoptLegacy(from: old.directory, now: Date().addingTimeInterval(3600)) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["t.json"])
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: old.directory.path)) == ["t.wav", "t.json"])
  }

  @Test func aSidecarIsOnlyRemovedOnceItsAudioIsGone() throws {
    guard getuid() != 0 else { return }
    let root = URL(fileURLWithPath: NSTemporaryDirectory() + "khuluma-rm-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("take")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: root) }
    let wav = dir.appendingPathComponent("a.wav"), sidecar = dir.appendingPathComponent("a.json")
    try Data([1]).write(to: wav)
    try Data([2]).write(to: sidecar)
    chmod(dir.path, 0o500)  // nothing in it can be removed
    #expect(!TimedOutTakes.removeTake(wav: wav, sidecar: sidecar))
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    chmod(dir.path, 0o700)
    #expect(TimedOutTakes.removeTake(wav: wav, sidecar: sidecar))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
  }
}
