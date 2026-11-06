import Darwin
import Foundation

/// Where the app's own daemon listens: `<support>/khulumad.sock`, or a short
/// per-user path under the temp dir when that is too long for `sun_path`.
/// Never the CLI's socket (`~/.config/khuluma/.cache/khulumad.sock`).
public enum DaemonSocketPath {
  /// `sun_path` is 104 bytes on macOS, NUL included.
  public static let maxBytes = 104

  public struct Resolved: Equatable, Sendable {
    public let path: String
    /// True when the support folder's path was too long.
    public let isFallback: Bool
  }

  public static func resolve(support: URL, temporary: URL = FileManager.default.temporaryDirectory,
                             uid: uid_t = getuid()) -> Resolved {
    let preferred = support.appendingPathComponent("khulumad.sock").path
    if fits(preferred) { return Resolved(path: preferred, isFallback: false) }
    // $TMPDIR is per user on macOS; the hash keeps two support folders
    // (an isolated test run and the daily app) apart.
    let name = "khuluma-\(shortHash(support.path)).sock"
    let temp = temporary.appendingPathComponent(name).path
    if fits(temp) { return Resolved(path: temp, isFallback: true) }
    // A long $TMPDIR too: a bounded path in a private (0700) per-user
    // folder, which `preparePrivateDirectory` creates and checks.
    return Resolved(path: privateDirectory(uid: uid) + "/" + shortHash(support.path) + ".sock", isFallback: true)
  }

  /// `resolve`, with the last-resort folder prepared: `issue` says why the
  /// socket must not be used (then nothing starts or connects on it).
  public static func prepared(support: URL) -> (resolved: Resolved, issue: String?) {
    let resolved = resolve(support: support)
    return (resolved, resolved.isFallback ? preparePrivateDirectory(for: resolved.path) : nil)
  }

  static func fits(_ path: String) -> Bool { path.utf8.count + 1 <= maxBytes }

  public static func privateDirectory(uid: uid_t = getuid()) -> String { "/private/tmp/khuluma-\(uid)" }

  /// For the last-resort fallback: makes sure its folder exists, is ours and
  /// is 0700 (nil), else says why (the socket must not be used).
  public static func preparePrivateDirectory(for path: String, uid: uid_t = getuid()) -> String? {
    let directory = (path as NSString).deletingLastPathComponent
    guard directory == privateDirectory(uid: uid) else { return nil }
    if mkdir(directory, 0o700) != 0 && errno != EEXIST {
      return "couldn't create \(directory): \(String(cString: strerror(errno)))"
    }
    var info = stat()
    guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid,
          (info.st_mode & 0o077) == 0 else {
      return "\(directory) isn't a private folder owned by this user"
    }
    return nil
  }

  /// FNV-1a, 32 bits, hex: stable across launches (Swift's hashValue isn't).
  static func shortHash(_ text: String) -> String {
    var hash: UInt32 = 0x811C_9DC5
    for byte in text.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 0x0100_0193
    }
    return String(format: "%08x", hash)
  }
}

/// Runs the bundled `khulumad` for one support folder: one owner at a time
/// (a `flock` on `<support>/.daemon.lock`), restarts after a crash with
/// backoff, and SIGTERM on quit. It only ever signals the child it spawned.
public final class DaemonProcess: @unchecked Sendable {
  /// A child we spawned. `terminate` signals it through the object that
  /// owns it (Process), and only while it hasn't exited, so a reaped pid that
  /// was reused is never signalled.
  public struct Child: Sendable {
    public let pid: Int32
    public let terminate: @Sendable () -> Void

    public init(pid: Int32, terminate: @escaping @Sendable () -> Void) {
      self.pid = pid
      self.terminate = terminate
    }
  }

  public enum Launch: Equatable, Sendable {
    /// Our child is running (or was just started).
    case running
    /// Something already answers on the socket (another app instance's
    /// daemon, or one left by a crashed instance): use it, don't spawn.
    case external
    /// Our child exited; a restart is scheduled.
    case restarting
    case unavailable(String)
  }

  /// The outside world, injectable for tests.
  public struct Environment: Sendable {
    /// Exclusive non-blocking lock; the open fd, or nil when held elsewhere.
    public var lock: @Sendable (_ path: String) -> Int32?
    public var unlock: @Sendable (_ fd: Int32) -> Void
    /// Starts `executable` with output appended to `logPath`; `onExit` gets
    /// the exit status (or signal) once. Returns the running child.
    public var spawn: @Sendable (_ executable: String, _ arguments: [String], _ logPath: String,
                                 _ onExit: @escaping @Sendable (Int32) -> Void) throws -> Child
    /// Whether a daemon answers on the socket.
    public var answers: @Sendable (_ socketPath: String) -> Bool
    public var now: @Sendable () -> Date
    public var schedule: @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    public init(
      lock: @escaping @Sendable (String) -> Int32?,
      unlock: @escaping @Sendable (Int32) -> Void,
      spawn: @escaping @Sendable (String, [String], String, @escaping @Sendable (Int32) -> Void) throws -> Child,
      answers: @escaping @Sendable (String) -> Bool,
      now: @escaping @Sendable () -> Date = { Date() },
      schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    ) {
      self.lock = lock
      self.unlock = unlock
      self.spawn = spawn
      self.answers = answers
      self.now = now
      self.schedule = schedule
    }
  }

  /// Restart delays after consecutive crashes, capped at the last.
  public static let restartBackoff: [TimeInterval] = [1, 5, 30, 120]
  /// A child that ran this long before exiting resets the backoff.
  public static let healthyAfter: TimeInterval = 300

  public let binary: String?
  public let socketPath: String
  public let lockPath: String
  public let logPath: String
  private let environment: Environment
  private let log: @Sendable (String) -> Void
  /// Set when the socket path is unsafe: never spawn or adopt anything.
  private let refusal: String?
  private let lock = NSLock()
  private var lockFD: Int32?
  private var child: Child?
  private var startedAt: Date?
  private var crashes = 0
  private var restartPending = false
  private var stopping = false
  private var exited: DispatchSemaphore?
  /// A daemon we didn't start answers on our socket (e.g. an orphan from a
  /// crashed run before khulumad exited with its parent): it is polled, never
  /// signalled, and replaced by ours once it stops answering.
  private var watchingExternal = false
  /// How often an adopted external daemon is checked.
  public static let externalCheckInterval: TimeInterval = 5
  /// Called (off the lock) after a daemon was started to replace one that
  /// exited or went away, so the model gets loaded again before the next
  /// take instead of on it.
  public var onRestart: (@Sendable () -> Void)? {
    get { lock.withLock { storedOnRestart } }
    set { lock.withLock { storedOnRestart = newValue } }
  }
  private var storedOnRestart: (@Sendable () -> Void)?

  public init(binary: String?, socketPath: String, support: URL, logDirectory: URL, environment: Environment,
              refusal: String? = nil, log: @escaping @Sendable (String) -> Void) {
    self.refusal = refusal
    self.binary = binary
    self.socketPath = socketPath
    self.lockPath = support.appendingPathComponent(".daemon.lock").path
    self.logPath = logDirectory.appendingPathComponent("khulumad.log").path
    self.environment = environment
    self.log = log
  }

  /// The bundled helper, or `KHULUMA_DAEMON_BINARY` in dev and test runs
  /// where the bundle has none. Never the CLI's own build of the daemon.
  public static func locateBinary(bundle: URL = Bundle.main.bundleURL,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let bundled = bundle.appendingPathComponent("Contents/Helpers/khulumad").path
    if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
    if let override = environment["KHULUMA_DAEMON_BINARY"], !override.isEmpty,
       FileManager.default.isExecutableFile(atPath: override) {
      return override
    }
    return nil
  }

  public var isOwner: Bool { lock.withLock { lockFD != nil } }
  public var childPid: Int32? { lock.withLock { child?.pid } }

  /// Makes sure a daemon will answer on the socket: spawns ours if we own
  /// the folder (or can take it) and none is running.
  public func ensureRunning() -> Launch {
    lock.lock()
    defer { lock.unlock() }
    guard !stopping else { return .unavailable("quitting") }
    if let refusal { return .unavailable(refusal) }
    if child != nil { return .running }
    if restartPending { return .restarting }
    if lockFD == nil {
      guard let fd = environment.lock(lockPath) else {
        // Another Khuluma owns this folder's daemon: use it if it answers.
        return environment.answers(socketPath)
          ? .external : .unavailable("another Khuluma instance runs the daemon and it isn't answering")
      }
      lockFD = fd
    }
    if environment.answers(socketPath) {
      watchExternalLocked()
      return .external
    }
    return spawnLocked()
  }

  private func watchExternalLocked() {
    guard !watchingExternal, !stopping else { return }
    watchingExternal = true
    log("daemon: a khulumad we didn't start answers on \(socketPath); using it and watching it")
    environment.schedule(Self.externalCheckInterval) { [weak self] in self?.checkExternal() }
  }

  private func checkExternal() {
    lock.lock()
    guard !stopping, child == nil else {
      watchingExternal = false
      lock.unlock()
      return
    }
    if environment.answers(socketPath) {
      environment.schedule(Self.externalCheckInterval) { [weak self] in self?.checkExternal() }
      lock.unlock()
      return
    }
    watchingExternal = false
    log("daemon: the khulumad we didn't start stopped answering; starting ours")
    let started: Bool
    if lockFD == nil, let fd = environment.lock(lockPath) { lockFD = fd }
    if lockFD != nil, case .running = spawnLocked() { started = true } else { started = false }
    let notify = storedOnRestart
    lock.unlock()
    if started { notify?() }
  }

  private func spawnLocked() -> Launch {
    guard let binary else { return .unavailable("khulumad isn't in the app bundle (set KHULUMA_DAEMON_BINARY in dev runs)") }
    do {
      let spawned = try environment.spawn(binary, ["serve", "--socket", socketPath, "--exit-with-parent"], logPath) { [weak self] status in
        self?.childExited(status: status)
      }
      child = spawned
      startedAt = environment.now()
      log("daemon: started khulumad (pid \(spawned.pid)) on \(socketPath)")
      return .running
    } catch {
      log("daemon: couldn't start khulumad: \(error.localizedDescription)")
      scheduleRestartLocked()
      return .unavailable("couldn't start khulumad: \(error.localizedDescription)")
    }
  }

  private func childExited(status: Int32) {
    lock.lock()
    let ranFor = startedAt.map { environment.now().timeIntervalSince($0) } ?? 0
    let pid = child?.pid
    child = nil
    startedAt = nil
    if stopping {
      let done = exited
      lock.unlock()
      log("daemon: khulumad (pid \(pid.map(String.init) ?? "?")) exited with status \(status) on quit")
      done?.signal()
      return
    }
    if ranFor >= Self.healthyAfter { crashes = 0 }
    log("daemon: khulumad (pid \(pid.map(String.init) ?? "?")) exited with status \(status) after \(Int(ranFor))s")
    scheduleRestartLocked()
    lock.unlock()
  }

  private func scheduleRestartLocked() {
    guard !restartPending, !stopping else { return }
    crashes += 1
    let delay = Self.restartBackoff[min(crashes, Self.restartBackoff.count) - 1]
    restartPending = true
    log("daemon: restarting khulumad in \(Int(delay))s")
    environment.schedule(delay) { [weak self] in self?.restart() }
  }

  private func restart() {
    lock.lock()
    defer { lock.unlock() }
    restartPending = false
    guard !stopping, child == nil, lockFD != nil else { return }
    if environment.answers(socketPath) {
      watchExternalLocked()
      return
    }
    if case .running = spawnLocked(), let notify = storedOnRestart {
      // Off the lock: the warm-up it starts calls back into ensureRunning.
      DispatchQueue.global(qos: .utility).async { notify() }
    }
  }

  /// Quit: SIGTERM our child (it drains its own in-flight work) and wait at
  /// most `timeout` for it, then release the folder lock. Never signals a
  /// pid we didn't spawn.
  public func stop(timeout: TimeInterval = 2) {
    lock.lock()
    stopping = true
    let running = child
    let done = running == nil ? nil : DispatchSemaphore(value: 0)
    exited = done
    // Under the lock the exit handler also takes: a child that already
    // exited has cleared `child`, so it's never signalled.
    running?.terminate()
    lock.unlock()
    if let running, let done {
      log("daemon: stopping khulumad (pid \(running.pid))")
      if done.wait(timeout: .now() + timeout) == .timedOut {
        log("daemon: khulumad still draining after \(timeout)s; quitting without waiting")
      }
    }
    lock.withLock {
      if let fd = lockFD { environment.unlock(fd) }
      lockFD = nil
    }
  }
}

extension DaemonProcess.Environment {
  /// This Mac: flock, Process, kill, and a ping on the socket.
  public static func live(schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)
    -> DaemonProcess.Environment {
    DaemonProcess.Environment(
      lock: FileLock.tryLockFD,
      unlock: FileLock.unlock,
      spawn: { executable, arguments, logPath, onExit in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        output.seekToEndOfFile()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
          try? output.close()
          onExit(finished.terminationStatus)
        }
        do {
          try process.run()
        } catch {
          try? output.close()
          throw error
        }
        // Foundation only signals a Process it hasn't reaped.
        return DaemonProcess.Child(pid: process.processIdentifier) {
          if process.isRunning { process.terminate() }
        }
      },
      answers: { path in DaemonClient(socketPath: path).status(timeout: 0.25) != nil },
      schedule: schedule)
  }
}

/// Exclusive, non-blocking `flock` on a lock file, held until released.
public enum FileLock {
  public static let tryLockFD: @Sendable (String) -> Int32? = { path in
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return nil
    }
    return fd
  }

  public static let unlock: @Sendable (Int32) -> Void = { fd in
    flock(fd, LOCK_UN)
    close(fd)
  }

  /// The lock's release, or nil when another holder has it.
  public static func tryLock(_ path: String) -> (@Sendable () -> Void)? {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    guard let fd = tryLockFD(path) else { return nil }
    return { unlock(fd) }
  }
}
