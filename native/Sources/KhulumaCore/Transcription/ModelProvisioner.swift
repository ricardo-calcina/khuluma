import Foundation

/// Gets the Parakeet model on first run: when no usable model is present,
/// downloads it once into FluidAudio's shared cache (the app supplies
/// FluidAudio's own download), reporting progress, retrying with backoff on
/// failure. Never blocks recording: takes made meanwhile are kept and
/// recovered once the model is ready.
public final class ModelProvisioner: @unchecked Sendable {
  public enum State: Equatable, Sendable {
    case unknown
    case present(String)
    /// Fraction in [0, 1].
    case downloading(Double)
    case failed(String)
  }

  public struct Environment: Sendable {
    /// A complete model is in this folder.
    public var isComplete: @Sendable (_ path: String) -> Bool
    /// The cache-wide download lock (across processes): its release, or nil
    /// when another process is downloading.
    public var lockDownload: @Sendable () -> (@Sendable () -> Void)?
    /// Downloads into the default cache: progress fractions, then `done`
    /// with the folder or an error, once.
    public var download: @Sendable (_ progress: @escaping @Sendable (Double) -> Void,
                                    _ done: @escaping @Sendable (Result<String, Error>) -> Void) -> Void
    public var schedule: @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    public init(isComplete: @escaping @Sendable (String) -> Bool,
                lockDownload: @escaping @Sendable () -> (@Sendable () -> Void)?,
                download: @escaping @Sendable (@escaping @Sendable (Double) -> Void,
                                               @escaping @Sendable (Result<String, Error>) -> Void) -> Void,
                schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void) {
      self.isComplete = isComplete
      self.lockDownload = lockDownload
      self.download = download
      self.schedule = schedule
    }
  }

  public static let retryBackoff: [TimeInterval] = [30, 120, 600]
  /// While another process downloads, check back this often.
  public static let waitForOtherDownload: TimeInterval = 15

  private let environment: Environment
  private let onChange: @Sendable (State) -> Void
  private let lock = NSLock()
  private var state: State = .unknown
  private var running = false
  private var retryPending = false
  private var failures = 0
  /// Last whole percent reported, so progress doesn't flood the menu.
  private var lastPercent = -1
  private var release: (@Sendable () -> Void)?

  public init(environment: Environment, onChange: @escaping @Sendable (State) -> Void) {
    self.environment = environment
    self.onChange = onChange
  }

  public var currentState: State { lock.withLock { state } }

  /// `configured` is the settings' model folder (if any), `fallback`
  /// FluidAudio's default cache folder. Starts a download when neither holds
  /// a complete model and none is running or waiting to retry.
  public func ensure(configured: String?, fallback: String) {
    if let configured, environment.isComplete(configured) { return set(.present(configured)) }
    if environment.isComplete(fallback) { return set(.present(fallback)) }
    let start = lock.withLock { () -> Bool in
      guard !running, !retryPending else { return false }
      running = true
      lastPercent = -1
      return true
    }
    guard start else { return }
    guard let release = environment.lockDownload() else {
      // Another Khuluma is downloading into the same cache: wait for it.
      lock.withLock {
        running = false
        retryPending = true
      }
      set(.downloading(0))
      environment.schedule(Self.waitForOtherDownload) { [weak self] in
        guard let self else { return }
        self.lock.withLock { self.retryPending = false }
        self.ensure(configured: configured, fallback: fallback)
      }
      return
    }
    // It may have finished while we waited for the lock.
    if environment.isComplete(fallback) {
      release()
      lock.withLock { running = false }
      return set(.present(fallback))
    }
    lock.withLock { self.release = release }
    set(.downloading(0))
    environment.download({ [weak self] fraction in self?.progress(fraction) }) { [weak self] result in
      self?.finished(result, configured: configured, fallback: fallback)
    }
  }

  private func progress(_ fraction: Double) {
    let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    let report = lock.withLock { () -> Bool in
      guard running, percent > lastPercent else { return false }
      lastPercent = percent
      return true
    }
    if report { set(.downloading(Double(percent) / 100)) }
  }

  private func finished(_ result: Result<String, Error>, configured: String?, fallback: String) {
    let release = lock.withLock { () -> (@Sendable () -> Void)? in
      defer { self.release = nil }
      return self.release
    }
    release?()
    switch result {
    case .success(let path) where environment.isComplete(path):
      lock.withLock {
        running = false
        failures = 0
      }
      set(.present(path))
    case .success(let path):
      fail("download finished but the model at \(path) is incomplete", configured: configured, fallback: fallback)
    case .failure(let error):
      fail(error.localizedDescription, configured: configured, fallback: fallback)
    }
  }

  private func fail(_ reason: String, configured: String?, fallback: String) {
    let delay = lock.withLock { () -> TimeInterval in
      running = false
      failures += 1
      retryPending = true
      return Self.retryBackoff[min(failures, Self.retryBackoff.count) - 1]
    }
    set(.failed("\(reason); retrying in \(Int(delay))s"))
    environment.schedule(delay) { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.retryPending = false }
      self.ensure(configured: configured, fallback: fallback)
    }
  }

  private func set(_ new: State) {
    let changed = lock.withLock { () -> Bool in
      defer { state = new }
      return state != new
    }
    if changed { onChange(new) }
  }
}

extension ModelProvisioner.State {
  /// The status-menu line, or nil when there is nothing to say.
  public var menuTitle: String? {
    switch self {
    case .unknown, .present: return nil
    case .downloading(let fraction): return "Downloading speech model… \(Int((fraction * 100).rounded(.down)))%"
    case .failed(let reason): return "Speech model download failed (\(reason))"
    }
  }
}

/// Whether a model folder is load-ready, judged the way FluidAudio's own
/// cache check is (ModelCache.incompleteFiles, which isn't public): every
/// compiled bundle has its root `coremldata.bin`, plain files exist, and no
/// `*.partial` download staging file remains anywhere. A bare directory
/// check passes for an interrupted download.
public enum ModelBundleCheck {
  public static func isComplete(_ path: String, required: Set<String>) -> Bool {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: path, isDirectory: true)
    for file in required {
      let url = root.appendingPathComponent(file)
      let needed = file.hasSuffix(".mlmodelc") ? url.appendingPathComponent("coremldata.bin") : url
      guard fm.fileExists(atPath: needed.path) else { return false }
    }
    guard let items = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
    for case let item as URL in items where item.pathExtension == "partial" { return false }
    return true
  }
}

/// Whether an incomplete model folder may be deleted and downloaded again.
/// The shared cache is also used by other apps: a folder that changed
/// recently may be someone else's download in progress, so it is left alone
/// and the provisioner's backoff tries again later.
public enum ModelRepair {
  public static let busyWindow: TimeInterval = 15 * 60

  public struct Busy: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "model folder busy, retrying later" }
  }

  /// The newest modification time of the folder or anything in it.
  public static func newestModification(_ path: String) -> Date? {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let key: URLResourceKey = .contentModificationDateKey
    var newest = (try? root.resourceValues(forKeys: [key]))?.contentModificationDate
    guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [key]) else { return newest }
    for case let item as URL in items {
      if let date = (try? item.resourceValues(forKeys: [key]))?.contentModificationDate, date > (newest ?? .distantPast) {
        newest = date
      }
    }
    return newest
  }

  /// True when the folder (or a file in it) changed within `busyWindow`.
  public static func isBusy(_ path: String, now: Date = Date()) -> Bool {
    guard let newest = newestModification(path) else { return false }
    return now.timeIntervalSince(newest) < busyWindow
  }
}
