import Darwin
import Foundation
import KhulumaDaemonKit
import Testing
@testable import KhulumaCore

/// A scripted world for DaemonProcess: fake spawns and signals, real or
/// fake locks, a settable clock and captured scheduled work.
private final class ProcessWorld: @unchecked Sendable {
  let lock = NSLock()
  var nextPid: Int32 = 100
  var spawned: [(pid: Int32, args: [String], log: String)] = []
  var exits: [Int32: @Sendable (Int32) -> Void] = [:]
  var signals: [(Int32, Int32)] = []
  var answers = false
  var spawnError: Error?
  var now = Date(timeIntervalSince1970: 1_000_000)
  var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
  var lines: [String] = []
  /// Fake lock: which paths are held (nil = use a real flock).
  var heldLocks: Set<String>?

  func environment() -> DaemonProcess.Environment {
    let real = DaemonProcess.Environment.live(schedule: { _, _ in })
    return DaemonProcess.Environment(
      lock: { path in
        guard self.lock.withLock({ self.heldLocks }) != nil else { return real.lock(path) }
        return self.lock.withLock { () -> Int32? in
          guard self.heldLocks!.insert(path).inserted else { return nil }
          return 42
        }
      },
      unlock: { fd in
        if self.lock.withLock({ self.heldLocks }) == nil { real.unlock(fd) }
      },
      spawn: { _, args, log, onExit in
        let pid = try self.lock.withLock { () -> Int32 in
          if let error = self.spawnError { throw error }
          self.nextPid += 1
          self.spawned.append((self.nextPid, args, log))
          self.exits[self.nextPid] = onExit
          return self.nextPid
        }
        return DaemonProcess.Child(pid: pid) {
          let exit = self.lock.withLock { () -> (@Sendable (Int32) -> Void)? in
            self.signals.append((pid, SIGTERM))
            return self.exits.removeValue(forKey: pid)
          }
          // The child handles SIGTERM and exits on another thread, as Process
          // does. Its own thread, not the global pool: a pool busy with the
          // rest of the suite could delay it past the test's bound. (Not
          // inline: `stop` signals under the lock the exit handler takes.)
          if let exit { Thread { exit(0) }.start() }
        }
      },
      answers: { _ in self.lock.withLock { self.answers } },
      now: { self.lock.withLock { self.now } },
      schedule: { delay, work in self.lock.withLock { self.scheduled.append((delay, work)) } })
  }

  func process(support: URL, binary: String? = "/bundle/Contents/Helpers/khulumad") -> DaemonProcess {
    DaemonProcess(binary: binary, socketPath: "/s.sock", support: support, logDirectory: URL(fileURLWithPath: "/logs"),
                  environment: environment()) { line in self.lock.withLock { self.lines.append(line) } }
  }

  /// The child exits on its own (crash).
  func crash(_ pid: Int32, status: Int32 = 6) {
    let exit = lock.withLock { exits.removeValue(forKey: pid) }
    exit?(status)
  }

  func runScheduled() -> [TimeInterval] {
    let work = lock.withLock { () -> [(TimeInterval, @Sendable () -> Void)] in
      defer { scheduled = [] }
      return scheduled
    }
    work.forEach { $0.1() }
    return work.map(\.0)
  }

  func advance(_ seconds: TimeInterval) { lock.withLock { now = now.addingTimeInterval(seconds) } }
  var spawnCount: Int { lock.withLock { spawned.count } }
}

private func temporaryFolder() throws -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("khuluma-daemon-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

struct DaemonSocketPathTests {
  @Test func usesTheSupportFolderWhenItFits() {
    let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Khuluma")
    let resolved = DaemonSocketPath.resolve(support: support)
    #expect(resolved == .init(path: support.path + "/khulumad.sock", isFallback: false))
  }

  @Test func fallsBackToAShortPerFolderTempPathWhenTooLong() {
    let long = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "deep/", count: 20) + "Khuluma")
    let temp = URL(fileURLWithPath: "/var/folders/xy/T")
    let resolved = DaemonSocketPath.resolve(support: long, temporary: temp)
    #expect(resolved.isFallback)
    #expect(resolved.path.hasPrefix("/var/folders/xy/T/khuluma-"))
    #expect(resolved.path.utf8.count + 1 <= DaemonSocketPath.maxBytes)
    // Stable across launches, distinct per folder.
    #expect(DaemonSocketPath.resolve(support: long, temporary: temp) == resolved)
    let other = DaemonSocketPath.resolve(support: long.appendingPathComponent("x"), temporary: temp)
    #expect(other.path != resolved.path)
  }

  @Test func exactlyAtTheLimitFallsBack() {
    // 103 bytes + NUL fits; 104 + NUL doesn't.
    let fits = "/" + String(repeating: "a", count: 103 - "/khulumad.sock".utf8.count - 1)
    #expect(!DaemonSocketPath.resolve(support: URL(fileURLWithPath: fits)).isFallback)
    #expect(DaemonSocketPath.resolve(support: URL(fileURLWithPath: fits + "a")).isFallback)
  }

  @Test func theAppNeverUsesTheConfiguredCLISocket() {
    var settings = AppSettings()
    settings.transcription.socketPath = "~/.config/khuluma/.cache/khulumad.sock"
    let env = SettingsEnvironment(appFolder: URL(fileURLWithPath: "/app"), home: "/home", soundsDir: "/s",
                                  modelsDir: "/m", defaultSocketPath: "/app/khulumad.sock",
                                  ffmpegAvailable: true, keyAvailable: false)
    #expect(AppConfig(settings: settings, environment: env).transcription.socketPath == "/app/khulumad.sock")
  }

  @Test func modelPathIsTheSettingsFolderIfPresentElseFluidAudiosCache() {
    var env = SettingsEnvironment(appFolder: URL(fileURLWithPath: "/app"), home: "/home", soundsDir: "/s",
                                  modelsDir: "/m", defaultSocketPath: "/app/khulumad.sock",
                                  ffmpegAvailable: true, keyAvailable: false)
    env.defaultModelPath = "/fluid/parakeet-tdt-0.6b-v3"
    var settings = AppSettings()
    settings.transcription.modelPath = "/mine/parakeet-tdt-0.6b-v3"
    env.modelAvailable = { p, _ in p == "/mine/parakeet-tdt-0.6b-v3" || p == "/fluid/parakeet-tdt-0.6b-v3" }
    #expect(settings.resolvedModelPath(in: env) == "/mine/parakeet-tdt-0.6b-v3")
    env.modelAvailable = { p, _ in p == "/fluid/parakeet-tdt-0.6b-v3" }
    #expect(settings.resolvedModelPath(in: env) == "/fluid/parakeet-tdt-0.6b-v3")
    env.modelAvailable = { _, _ in false }
    #expect(settings.resolvedModelPath(in: env) == nil)
    let config = AppConfig(settings: settings, environment: env)
    #expect(config.nativePipelineBlocker == "speech model still downloading")
    #expect(DaemonSupervisor.Target(config: config) == nil)
  }
}

struct DaemonProcessTests {
  @Test func spawnsTheHelperOnTheAppSocketWithItsLog() throws {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    #expect(process.ensureRunning() == .running)
    #expect(world.spawned.count == 1)
    #expect(world.spawned[0].args == ["serve", "--socket", "/s.sock", "--exit-with-parent"])
    #expect(world.spawned[0].log == "/logs/khulumad.log")
    #expect(world.heldLocks == ["/support/.daemon.lock"])
    // Running: no second spawn.
    #expect(process.ensureRunning() == .running)
    #expect(world.spawnCount == 1)
  }

  @Test func aSecondOwnerOfTheFolderDoesNotSpawn() throws {
    let support = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: support) }
    let world = ProcessWorld() // real flock
    let first = world.process(support: support)
    let second = world.process(support: support)
    #expect(first.ensureRunning() == .running)
    #expect(first.isOwner)
    #expect(second.ensureRunning() == .unavailable("another Khuluma instance runs the daemon and it isn't answering"))
    world.answers = true
    #expect(second.ensureRunning() == .external)
    #expect(!second.isOwner)
    #expect(world.spawnCount == 1)
    // Once the first lets go, the second can take over.
    first.stop(timeout: 1)
    world.answers = false
    #expect(second.ensureRunning() == .running)
    #expect(second.isOwner)
    #expect(world.spawnCount == 2)
    second.stop(timeout: 1)
  }

  @Test func anAnsweringDaemonIsUsedNotReplaced() {
    let world = ProcessWorld()
    world.heldLocks = []
    world.answers = true
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    #expect(process.ensureRunning() == .external)
    #expect(world.spawnCount == 0)
    process.stop()
    #expect(world.signals.isEmpty, "never signals a daemon we didn't spawn")
  }

  /// An orphan on our socket is used, polled, never signalled, and replaced
  /// by ours (with a re-warm) once it goes away.
  @Test func anAdoptedExternalDaemonIsWatchedAndReplaced() {
    let world = ProcessWorld()
    world.heldLocks = []
    world.answers = true
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    let restarts = Counter()
    process.onRestart = { restarts.increment() }
    #expect(process.ensureRunning() == .external)
    #expect(process.ensureRunning() == .external)
    #expect(world.runScheduled() == [DaemonProcess.externalCheckInterval], "one watch, not one per call")
    #expect(world.spawnCount == 0)
    // Still answering: keep watching.
    #expect(world.runScheduled() == [DaemonProcess.externalCheckInterval])
    // kill -9 on it: ours starts, and the supervisor is told to warm it.
    world.answers = false
    _ = world.runScheduled()
    #expect(world.spawnCount == 1)
    #expect(restarts.value == 1)
    #expect(world.lines.contains { $0.contains("stopped answering") })
    process.stop()
    #expect(world.signals.map(\.0) == [world.spawned[0].pid], "only our own child is signalled")
  }

  @Test func aRestartAfterACrashAsksForARewarm() async throws {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    let restarts = Counter()
    process.onRestart = { restarts.increment() }
    #expect(process.ensureRunning() == .running)
    #expect(restarts.value == 0, "the first start is warmed by the supervisor's own call")
    world.crash(world.spawned[0].pid)
    _ = world.runScheduled()
    #expect(world.spawnCount == 2)
    for _ in 0..<50 where restarts.value == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(restarts.value == 1)
  }

  @Test func noHelperMeansUnavailableNeverTheCLI() {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"), binary: nil)
    guard case .unavailable(let reason) = process.ensureRunning() else { Issue.record("expected unavailable"); return }
    #expect(reason.contains("KHULUMA_DAEMON_BINARY"))
    #expect(world.spawnCount == 0)
  }

  @Test func locatesTheBundledHelperElseTheOverride() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Khuluma.app")
    let override = root.appendingPathComponent("khulumad-dev").path
    FileManager.default.createFile(atPath: override, contents: Data(), attributes: [.posixPermissions: 0o755])
    #expect(DaemonProcess.locateBinary(bundle: bundle, environment: [:]) == nil)
    #expect(DaemonProcess.locateBinary(bundle: bundle, environment: ["KHULUMA_DAEMON_BINARY": override]) == override)
    let helpers = bundle.appendingPathComponent("Contents/Helpers")
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: helpers.appendingPathComponent("khulumad").path, contents: Data(),
                                   attributes: [.posixPermissions: 0o755])
    #expect(DaemonProcess.locateBinary(bundle: bundle, environment: ["KHULUMA_DAEMON_BINARY": override])
      == helpers.appendingPathComponent("khulumad").path)
  }

  @Test func crashesRestartWithBackoffThatResetsAfterHealthyRunning() {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    _ = process.ensureRunning()
    var delays: [TimeInterval] = []
    for _ in 0..<5 {
      world.crash(process.childPid!)
      #expect(process.ensureRunning() == .restarting)
      delays += world.runScheduled()
    }
    #expect(delays == [1, 5, 30, 120, 120])
    #expect(world.spawnCount == 6)
    // Healthy for 5 minutes: the next crash starts again at 1 s.
    world.advance(DaemonProcess.healthyAfter)
    world.crash(process.childPid!)
    #expect(world.runScheduled() == [1])
    #expect(world.lines.contains { $0.contains("exited with status 6") })
  }

  @Test func aFailedSpawnRetriesWithBackoff() {
    struct Nope: Error {}
    let world = ProcessWorld()
    world.heldLocks = []
    world.spawnError = Nope()
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    guard case .unavailable = process.ensureRunning() else { Issue.record("expected unavailable"); return }
    world.spawnError = nil
    #expect(world.runScheduled() == [1])
    #expect(process.childPid != nil)
  }

  @Test func quitSendsSIGTERMOnlyToOurChildAndDoesNotRestart() {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    _ = process.ensureRunning()
    let pid = process.childPid!
    let started = Date()
    process.stop(timeout: 2)
    #expect(Date().timeIntervalSince(started) < 1.5, "the child exited on SIGTERM; no need to wait")
    #expect(world.signals.map(\.0) == [pid])
    #expect(world.signals.map(\.1) == [SIGTERM])
    #expect(world.scheduled.isEmpty, "no restart after quit")
    #expect(process.ensureRunning() == .unavailable("quitting"))
    #expect(world.heldLocks == ["/support/.daemon.lock"] && !process.isOwner)
  }

  @Test func quitDoesNotWaitLongForAChildStillDraining() {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    _ = process.ensureRunning()
    // This child ignores SIGTERM for now (draining).
    world.lock.withLock { world.exits = [:] }
    let started = Date()
    process.stop(timeout: 0.3)
    let waited = Date().timeIntervalSince(started)
    #expect(waited >= 0.25 && waited < 1.5)
    #expect(world.lines.contains { $0.contains("still draining") })
  }
}

struct OwnedWarmupTests {
  private let target = DaemonSupervisor.Target(socketPath: "/s.sock", modelPath: "/m", modelVersion: "v3")

  @Test func startsTheDaemonWaitsForTheSocketThenWarms() throws {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    let polls = Counter()
    let warmed = Counter()
    let warmup = DaemonSupervisor.ownedWarmup(
      process: process, answers: { _ in polls.increment() >= 3 },
      warm: { target in
        #expect(target.modelPath == "/m" && target.modelVersion == "v3")
        warmed.increment()
        return 1234
      }, sleep: { _ in })
    let report = try warmup(target)
    #expect(report == WarmupReport(state: .ready, durationMs: 1234))
    #expect(world.spawnCount == 1)
    #expect(warmed.value == 1)
  }

  @Test func reportsStartingRestartingAndDaemonErrors() throws {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    let never = DaemonSupervisor.ownedWarmup(process: process, answers: { _ in false }, warm: { _ in 1 },
                                             startupWait: 1, sleep: { _ in })
    #expect(try never(target).state == .warming)

    world.crash(process.childPid!)
    #expect(try never(target) == WarmupReport(state: .warming, reason: "restarting", message: "the daemon is restarting"))
    _ = world.runScheduled()

    let refused = DaemonSupervisor.ownedWarmup(
      process: process, answers: { _ in true },
      warm: { _ in throw DaemonClient.ClientError.daemon(code: "model_path_invalid", message: "bad model") },
      sleep: { _ in })
    #expect(try refused(target) == WarmupReport(state: .unavailable, reason: "model_path_invalid", message: "bad model"))

    let none = world.process(support: URL(fileURLWithPath: "/other"), binary: nil)
    let missing = DaemonSupervisor.ownedWarmup(process: none, answers: { _ in false }, warm: { _ in 1 }, sleep: { _ in })
    #expect(try missing(target).state == .unavailable)
  }

  @Test func theSupervisorWarmsThroughTheOwnedDaemon() throws {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    let warmed = Counter()
    let loaded = Flag()
    let supervisor = DaemonSupervisor(
      environment: DaemonSupervisor.Environment(
        probe: { _, _ in
          loaded.value ? DaemonStatus(version: "0.3.0", generation: "g1",
                                      modelLoaded: .init(path: "/m", version: "v3")) : nil
        },
        warmup: DaemonSupervisor.ownedWarmup(process: process, answers: { _ in true }, warm: { _ in
          warmed.increment()
          loaded.value = true
          return 900
        }, sleep: { _ in }),
        schedule: { _, _ in }),
      onChange: { _, _ in })
    supervisor.configure(target)
    supervisor.run(.launch)
    #expect(supervisor.currentState == .ready(generation: "g1"))
    #expect(world.spawnCount == 1)
    #expect(warmed.value == 1)
  }
}

struct ModelProvisionerTests {
  private final class Downloads: @unchecked Sendable {
    let lock = NSLock()
    var present: Set<String> = []
    var started = 0
    var progress: (@Sendable (Double) -> Void)?
    var done: (@Sendable (Result<String, Error>) -> Void)?
    var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
    var states: [ModelProvisioner.State] = []
    /// A real cross-process lock file, shared by two provisioners.
    var lockPath: String?

    func provisioner() -> ModelProvisioner {
      ModelProvisioner(environment: ModelProvisioner.Environment(
        isComplete: { path in self.lock.withLock { self.present.contains(path) } },
        lockDownload: { if let path = self.lockPath { return FileLock.tryLock(path) }; return {} },
        download: { progress, done in
          self.lock.withLock {
            self.started += 1
            self.progress = progress
            self.done = done
          }
        },
        schedule: { delay, work in self.lock.withLock { self.scheduled.append((delay, work)) } })
      ) { state in self.lock.withLock { self.states.append(state) } }
    }
  }

  private struct Offline: Error, LocalizedError { var errorDescription: String? { "offline" } }

  @Test func usesAModelAlreadyThere() {
    let world = Downloads()
    world.present = ["/fluid"]
    let models = world.provisioner()
    models.ensure(configured: "/missing", fallback: "/fluid")
    #expect(models.currentState == .present("/fluid"))
    #expect(world.started == 0)
  }

  @Test func downloadsOnceWithProgressThenReportsReady() {
    let world = Downloads()
    let models = world.provisioner()
    models.ensure(configured: nil, fallback: "/fluid")
    models.ensure(configured: nil, fallback: "/fluid")
    #expect(world.started == 1, "one download at a time")
    #expect(models.currentState.menuTitle == "Downloading speech model… 0%")
    world.progress?(0.421)
    world.progress?(0.425)
    world.progress?(0.3)
    #expect(models.currentState.menuTitle == "Downloading speech model… 42%")
    // The app re-resolves settings and recovers leftover takes on `.present`.
    world.present = ["/fluid"]
    world.done?(.success("/fluid"))
    #expect(models.currentState == .present("/fluid"))
    #expect(world.states == [.downloading(0), .downloading(0.42), .present("/fluid")])
    #expect(models.currentState.menuTitle == nil)
  }

  @Test func failuresRetryWithBackoff() {
    let world = Downloads()
    let models = world.provisioner()
    models.ensure(configured: nil, fallback: "/fluid")
    world.done?(.failure(Offline()))
    guard case .failed(let reason) = models.currentState else { Issue.record("expected failed"); return }
    #expect(reason == "offline; retrying in 30s")
    // While waiting to retry, triggers don't start another download.
    models.ensure(configured: nil, fallback: "/fluid")
    #expect(world.started == 1)
    var delays: [TimeInterval] = []
    for _ in 0..<3 {
      let work = world.lock.withLock { () -> [(TimeInterval, @Sendable () -> Void)] in
        defer { world.scheduled = [] }
        return world.scheduled
      }
      delays += work.map(\.0)
      work.forEach { $0.1() }
      world.done?(.failure(Offline()))
    }
    #expect(delays == [30, 120, 600])
    #expect(world.started == 4)
    // An incomplete result counts as a failure too.
    let work = world.lock.withLock { world.scheduled }
    world.lock.withLock { world.scheduled = [] }
    work.forEach { $0.1() }
    world.done?(.success("/fluid"))
    guard case .failed = models.currentState else { Issue.record("expected failed"); return }
  }
}

/// Spawns the freshly built khulumad on a short temp socket and pings it.
/// Skipped when the binary isn't built next to the test bundle (or named by
/// KHULUMA_DAEMON_BINARY).
struct BundledDaemonIntegrationTests {
  static var builtDaemon: String? {
    if let override = ProcessInfo.processInfo.environment["KHULUMA_DAEMON_BINARY"],
       FileManager.default.isExecutableFile(atPath: override) { return override }
    // The test bundle sits in the build products folder, beside khulumad.
    let candidate = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("khulumad").path
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
  }

  @Test(.enabled(if: builtDaemon != nil, "khulumad isn't built"))
  func spawnsTheBuiltDaemonAndPingsIt() throws {
    let root = URL(fileURLWithPath: "/private/tmp/kd-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let socket = DaemonSocketPath.resolve(support: root).path
    let process = DaemonProcess(
      binary: Self.builtDaemon, socketPath: socket, support: root, logDirectory: root,
      environment: .live(schedule: { delay, work in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) }),
      log: { _ in })
    #expect(process.ensureRunning() == .running)
    var status: DaemonStatus?
    for _ in 0..<50 where status == nil {
      status = DaemonClient(socketPath: socket).status(timeout: 0.5)
      if status == nil { Thread.sleep(forTimeInterval: 0.1) }
    }
    #expect(status?.pid.map(Int32.init) == process.childPid)
    #expect(status?.modelLoaded == nil)
    process.stop(timeout: 2)
    #expect(process.childPid == nil)
    #expect(DaemonClient(socketPath: socket).status(timeout: 0.3) == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("khulumad.log").path))
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool {
    get { lock.withLock { flag } }
    set { lock.withLock { flag = newValue } }
  }
}

private final class BundleAnchor: NSObject {}

struct ReviewFixTests {
  // P2-6: a long $TMPDIR too falls back to a bounded private folder.
  @Test func aLongTMPDIRFallsBackToAPrivatePerUserFolder() throws {
    let long = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "deep/", count: 20) + "Khuluma")
    let longTemp = URL(fileURLWithPath: "/private/var/folders/" + String(repeating: "t", count: 100))
    let resolved = DaemonSocketPath.resolve(support: long, temporary: longTemp, uid: 501)
    #expect(resolved.isFallback)
    #expect(resolved.path.hasPrefix("/private/tmp/khuluma-501/"))
    #expect(resolved.path.utf8.count + 1 <= DaemonSocketPath.maxBytes)

    // The folder is created 0700 and checked; a foreign-mode one is refused.
    let mine = DaemonSocketPath.resolve(support: long, temporary: longTemp)
    #expect(DaemonSocketPath.preparePrivateDirectory(for: mine.path) == nil)
    var info = stat()
    #expect(lstat(DaemonSocketPath.privateDirectory(), &info) == 0 && (info.st_mode & 0o777) == 0o700)
    chmod(DaemonSocketPath.privateDirectory(), 0o755)
    defer { chmod(DaemonSocketPath.privateDirectory(), 0o700) }
    #expect(DaemonSocketPath.preparePrivateDirectory(for: mine.path) != nil)
  }

  // P2-5: a missing configured v2 model falls back to the downloaded v3, as v3.
  @Test func fallingBackToTheCacheResolvesItsVersionToo() {
    var env = SettingsEnvironment(appFolder: URL(fileURLWithPath: "/app"), home: "/home", soundsDir: "/s",
                                  modelsDir: "/m", defaultSocketPath: "/app/khulumad.sock",
                                  ffmpegAvailable: true, keyAvailable: false)
    env.defaultModelPath = "/fluid/parakeet-tdt-0.6b-v3"
    var settings = AppSettings()
    settings.transcription.modelPath = "/mine/parakeet-custom"
    settings.transcription.modelVersion = "v2"
    env.modelAvailable = { p, _ in p == "/fluid/parakeet-tdt-0.6b-v3" }
    let fallback = AppConfig(settings: settings, environment: env).transcription
    #expect(fallback.modelPath == "/fluid/parakeet-tdt-0.6b-v3")
    #expect(fallback.modelVersion == "v3")
    env.modelAvailable = { _, _ in true }
    let configured = AppConfig(settings: settings, environment: env).transcription
    #expect(configured.modelPath == "/mine/parakeet-custom")
    #expect(configured.modelVersion == "v2")
  }

  // P2-4: a child that exits between capture and quit is never signalled.
  @Test func aChildThatAlreadyExitedIsNotSignalledOnQuit() {
    let world = ProcessWorld()
    world.heldLocks = []
    let process = world.process(support: URL(fileURLWithPath: "/support"))
    _ = process.ensureRunning()
    let pid = process.childPid!
    world.crash(pid, status: 0)
    process.stop(timeout: 0.2)
    #expect(world.signals.isEmpty)
    #expect(world.scheduled.count == 1, "its restart was scheduled before quit; the restart itself is a no-op")
    _ = world.runScheduled()
    #expect(world.spawnCount == 1)
  }

  // P2-3: an interrupted download isn't a model.
  @Test func anInterruptedCacheIsIncomplete() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let required: Set<String> = ["Encoder.mlmodelc", "Decoder.mlmodelc", "parakeet_vocab.json"]
    let fm = FileManager.default
    for bundle in ["Encoder.mlmodelc", "Decoder.mlmodelc"] {
      try fm.createDirectory(at: root.appendingPathComponent(bundle + "/weights"), withIntermediateDirectories: true)
    }
    fm.createFile(atPath: root.appendingPathComponent("parakeet_vocab.json").path, contents: Data())
    // Folders and vocab only (what FluidAudio's modelsExist accepts).
    #expect(!ModelBundleCheck.isComplete(root.path, required: required))
    for bundle in ["Encoder.mlmodelc", "Decoder.mlmodelc"] {
      fm.createFile(atPath: root.appendingPathComponent(bundle + "/coremldata.bin").path, contents: Data())
    }
    let partial = root.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.partial")
    fm.createFile(atPath: partial.path, contents: Data())
    #expect(!ModelBundleCheck.isComplete(root.path, required: required), "a .partial remains")
    try fm.removeItem(at: partial)
    #expect(ModelBundleCheck.isComplete(root.path, required: required))
  }
}

struct ProvisionerLockTests {
  private final class World: @unchecked Sendable {
    let lock = NSLock()
    var present = false
    var downloads = 0
    var done: [@Sendable (Result<String, Error>) -> Void] = []
    var scheduled: [@Sendable () -> Void] = []

    func provisioner(lockPath: String) -> ModelProvisioner {
      ModelProvisioner(environment: ModelProvisioner.Environment(
        isComplete: { _ in self.lock.withLock { self.present } },
        lockDownload: { FileLock.tryLock(lockPath) },
        download: { _, done in self.lock.withLock { self.downloads += 1; self.done.append(done) } },
        schedule: { _, work in self.lock.withLock { self.scheduled.append(work) } })
      ) { _ in }
    }
  }

  // P2-2: two instances on one cache download once; the second waits, then
  // finds the model complete.
  @Test func twoProvisionersShareOneCacheWideDownload() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let lockPath = root.appendingPathComponent(".khuluma-download.lock").path
    let world = World()
    let first = world.provisioner(lockPath: lockPath)
    let second = world.provisioner(lockPath: lockPath)
    first.ensure(configured: nil, fallback: "/fluid")
    second.ensure(configured: nil, fallback: "/fluid")
    #expect(world.downloads == 1)
    #expect(world.scheduled.count == 1, "the second checks back later")
    world.present = true
    world.done[0](.success("/fluid"))
    #expect(first.currentState == .present("/fluid"))
    world.scheduled.removeFirst()()
    #expect(second.currentState == .present("/fluid"))
    #expect(world.downloads == 1)
    // The lock was released: a later download can take it.
    #expect(FileLock.tryLock(lockPath) != nil)
  }
}

/// P1-1: a cold model load that outlasts the take's timeout is "not ready",
/// not a timed-out take.
struct DaemonReadinessTests {
  private actor SlowLoad: DaemonRequestHandling {
    var loaded = false
    func handle(_ request: DaemonRequest) async -> DaemonResponse {
      switch request.op {
      case .ping:
        return DaemonResponse(id: request.id, ok: true, version: "0.3.0", activeRequests: 1, pid: 1, generation: "g",
                              modelLoaded: loaded ? .init(path: "/m", version: "v3") : nil)
      case .warmup, .transcribe:
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        loaded = true
        return DaemonResponse(id: request.id, ok: true, text: "hello")
      }
    }
  }

  @Test func aLoadLongerThanTheTakeTimeoutIsNotReady() async throws {
    let path = NSTemporaryDirectory() + "khuluma-\(UUID().uuidString.prefix(8)).sock"
    let server = UnixSocketServer(socketPath: path, handler: SlowLoad())
    try server.start()
    defer { server.stop() }
    let client = DaemonClient(socketPath: path)
    let reason = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        do {
          _ = try client.transcribe(wav: URL(fileURLWithPath: "/tmp/x.wav"), language: "en", flow: "inline",
                                    modelPath: "/m", modelVersion: "v3", timeout: 0.3)
          continuation.resume(returning: "no error" as String?)
        } catch {
          continuation.resume(returning: DaemonReadiness.notReadyReason(
            error, modelPath: "/m", modelVersion: "v3", statusAfter: { client.status(timeout: 1) }))
        }
      }
    }
    #expect(reason == "speech model still loading")
  }

  @Test func classifiesFailures() {
    let warm = DaemonStatus(version: "0.3.0", modelLoaded: .init(path: "/m", version: "v3"))
    func reason(_ error: Error, _ status: DaemonStatus?) -> String? {
      DaemonReadiness.notReadyReason(error, modelPath: "/m", modelVersion: "v3", statusAfter: { status })
    }
    #expect(reason(DaemonClient.ClientError.unreachable("x"), nil) == "daemon not running yet")
    #expect(reason(DaemonClient.ClientError.timedOut(5), nil) == "daemon not answering")
    #expect(reason(DaemonClient.ClientError.timedOut(5), DaemonStatus(version: "0.3.0")) == "speech model still loading")
    // A warm daemon that timed out is a real timeout (Retry list).
    #expect(reason(DaemonClient.ClientError.timedOut(5), warm) == nil)
    #expect(reason(DaemonClient.ClientError.daemon(code: "x", message: "y"), nil) == nil)
  }
}

struct ReReviewFixTests {
  // 1: a take saved after the supervisor already went ready is recovered
  // now; saved before ready, the ready notification recovers it; saved
  // after the model arrived, the new settings are applied first.
  @Test func aKeptTakeIsFollowedUpInEitherOrder() {
    #expect(KeptTakeFollowUp.decide(settingsChanged: false, supervisorReady: true) == .recoverNow)
    #expect(KeptTakeFollowUp.decide(settingsChanged: false, supervisorReady: false) == .waitForReady)
    #expect(KeptTakeFollowUp.decide(settingsChanged: true, supervisorReady: false) == .applySettings)
    #expect(KeptTakeFollowUp.decide(settingsChanged: true, supervisorReady: true) == .applySettings)
  }

  // 2: an unsafe socket folder: nothing spawns or is adopted on it.
  @Test func anUnsafeSocketIsRefused() {
    let world = ProcessWorld()
    world.heldLocks = []
    world.answers = true
    let process = DaemonProcess(binary: "/k", socketPath: "/private/tmp/khuluma-501/x.sock",
                                support: URL(fileURLWithPath: "/support"), logDirectory: URL(fileURLWithPath: "/logs"),
                                environment: world.environment(), refusal: "unsafe socket folder: not private",
                                log: { _ in })
    #expect(process.ensureRunning() == .unavailable("unsafe socket folder: not private"))
    #expect(world.spawnCount == 0)
    #expect(world.heldLocks?.isEmpty == true)
    let warmup = DaemonSupervisor.ownedWarmup(process: process, answers: { _ in true }, warm: { _ in 1 }, sleep: { _ in })
    let report = try? warmup(DaemonSupervisor.Target(socketPath: "", modelPath: "/m", modelVersion: "v3"))
    #expect(report == WarmupReport(state: .unavailable, reason: "daemon", message: "unsafe socket folder: not private"))
    // An empty socket path (what the app's settings get) never connects.
    #expect(DaemonClient(socketPath: "").status(timeout: 0.2) == nil)
  }

  // 3: the configured folder is validated as its explicit version.
  @Test func aCustomNamedV2FolderIsCheckedAsV2() {
    var env = SettingsEnvironment(appFolder: URL(fileURLWithPath: "/app"), home: "/home", soundsDir: "/s",
                                  modelsDir: "/m", defaultSocketPath: "/app/khulumad.sock",
                                  ffmpegAvailable: true, keyAvailable: false)
    env.defaultModelPath = "/fluid/parakeet-tdt-0.6b-v3"
    let asked = Box()
    env.modelAvailable = { path, version in
      asked.add("\(path)@\(version)")
      return path == "/mine/custom" ? version == "v2" : true
    }
    var settings = AppSettings()
    settings.transcription.modelPath = "/mine/custom"
    settings.transcription.modelVersion = "v2"
    let transcription = AppConfig(settings: settings, environment: env).transcription
    #expect(transcription.modelPath == "/mine/custom")
    #expect(transcription.modelVersion == "v2")
    #expect(asked.items.first == "/mine/custom@v2")
    // The default cache is always checked as v3.
    settings.transcription.modelPath = ""
    asked.reset()
    _ = AppConfig(settings: settings, environment: env)
    #expect(asked.items == ["/fluid/parakeet-tdt-0.6b-v3@v3"])
  }
}

private final class Box: @unchecked Sendable {
  private let lock = NSLock()
  private var list: [String] = []
  var items: [String] { lock.withLock { list } }
  func add(_ item: String) { lock.withLock { list.append(item) } }
  func reset() { lock.withLock { list = [] } }
}
