import AppKit
import KhulumaCore

/// What the stats window shows, refreshed from `usage --json` only while the
/// window is open: on open/key, on ledger changes, at midnight, on a time
/// zone change, on wake and from the Refresh button. Never polls.
@MainActor
final class StatsModel: ObservableObject {
  /// The CLI and its last settings, read when a load starts.
  struct Source {
    let cli: CLIBridge?
    let config: AppConfig?
  }

  static let ranges = [30, 60, 90]
  private static let rangeKey = "KhulumaStatsRangeDays"
  private static let wordsKey = "KhulumaStatsWordsPerDay"
  private static let milestoneKey = "KhulumaStatsMilestoneSeen"

  @Published private(set) var stats: UsageStats?
  @Published private(set) var updatedAt: Date?
  /// The last refresh failed; the last good stats stay up.
  @Published private(set) var refreshFailed = false
  /// The milestone passed since the window last showed stats, celebrated
  /// once while it stays open.
  @Published private(set) var celebrating: Int?
  @Published var rangeDays: Int {
    didSet { if !fixture { AppRuntimePaths.defaults.set(rangeDays, forKey: Self.rangeKey) } }
  }

  /// Whether Activity also charts words per day. On unless turned off.
  @Published var showWordsPerDay: Bool {
    didSet { if !fixture { AppRuntimePaths.defaults.set(showWordsPerDay, forKey: Self.wordsKey) } }
  }

  private let source: () -> Source
  private let fixture: Bool
  private let queue = DispatchQueue(label: "khuluma.stats", qos: .utility)
  private var refresh = StatsRefresh()
  private var open = false
  private var windowOpen = false
  private var menuOpen = false
  private var watcher: DispatchSourceFileSystemObject?
  private var watchedPath: String?
  private var ledgerSignature: FileSignature?
  private var debounce: DispatchWorkItem?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(source: @escaping () -> Source) {
    self.source = source
    fixture = false
    let stored = AppRuntimePaths.defaults.integer(forKey: Self.rangeKey)
    rangeDays = Self.ranges.contains(stored) ? stored : 30
    showWordsPerDay = AppRuntimePaths.defaults.object(forKey: Self.wordsKey) as? Bool ?? true
  }

  /// Fixed content, for snapshots.
  init(stats: UsageStats?, updatedAt: Date?, rangeDays: Int = 30, celebrating: Int? = nil,
       refreshFailed: Bool = false) {
    source = { Source(cli: nil, config: nil) }
    fixture = true
    self.stats = stats
    self.updatedAt = updatedAt
    self.rangeDays = rangeDays
    showWordsPerDay = true
    self.celebrating = celebrating
    self.refreshFailed = refreshFailed
  }

  // MARK: - Window lifecycle

  func windowOpened() {
    windowOpen = true
    beginObserving()
  }

  func menuOpened() {
    menuOpen = true
    beginObserving()
  }

  func menuClosed() {
    menuOpen = false
    if !windowOpen { endObserving() }
  }

  private func beginObserving() {
    guard !fixture else { return }
    guard !open else { return reload() }
    open = true
    let centers = [NotificationCenter.default, NSWorkspace.shared.notificationCenter]
    for (center, name) in [(centers[0], Notification.Name.NSCalendarDayChanged),
                           (centers[0], Notification.Name.NSSystemTimeZoneDidChange),
                           (centers[1], NSWorkspace.didWakeNotification)] {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      }
      observers.append((center, token))
    }
    reload()
  }

  /// Coming back to the window: fresh numbers, unless a load is already
  /// on its way (as when the window has just opened).
  func windowBecameKey() {
    guard open, !refresh.running else { return }
    reload()
  }

  func windowClosed() {
    windowOpen = false
    if !menuOpen { endObserving() }
  }

  private func endObserving() {
    open = false
    refresh.invalidate()
    debounce?.cancel()
    debounce = nil
    stopWatching()
    for (center, token) in observers {
      center.removeObserver(token)
    }
    observers = []
    celebrating = nil
  }

  // MARK: - Loading

  func reload() {
    guard !fixture, open, let generation = refresh.request() else { return }
    load(generation)
  }

  private func load(_ generation: Int) {
    let source = source()
    guard let cli = source.cli else {
      return finished(.failure(CLIBridge.BridgeError.notInstalled), generation: generation,
                      ledger: Self.ledgerPath(nil), before: nil)
    }
    let cached = source.config
    queue.async { [weak self] in
      // Settings may not have loaded yet (Khuluma just launched).
      let config = cached ?? (try? cli.appConfig())
      // The ledger as it was before the read: a write after this point is
      // seen as a change once the watcher is up.
      let path = Self.ledgerPath(config)
      let before = FileSignature(path: path)
      let result = Result { try cli.usage() }
      DispatchQueue.main.async {
        self?.finished(result, generation: generation, ledger: path, before: before)
      }
    }
  }

  private func finished(_ result: Result<UsageReport, Error>, generation: Int, ledger: String,
                        before: FileSignature?) {
    let (show, again) = refresh.finished(generation: generation)
    if show {
      switch result {
      case .success(let report):
        let calendar = Calendar.current
        let stats = UsageStats(report: report, today: CivilDate(Date()), firstWeekday: calendar.firstWeekday)
        Log.write("stats: refreshed (daily \(report.daily?.status ?? "absent"), \(report.daily?.days.count ?? 0) days)")
        noteMilestone(words: stats.lifetime.words)
        self.stats = stats
        updatedAt = Date()
        refreshFailed = false
      case .failure(let error):
        Log.write("stats: refresh failed: \(error.localizedDescription)")
        refreshFailed = true
      }
      watch(ledger, baseline: before)
    }
    if let again {
      load(again)
    }
  }

  private func noteMilestone(words: Int) {
    let defaults = AppRuntimePaths.defaults
    let seen = defaults.object(forKey: Self.milestoneKey) as? Int
    if let crossed = UsageStats.milestoneCrossed(words: words, lastSeen: seen) {
      celebrating = crossed
    }
    // A milestone passed before the first look is progress, not news.
    defaults.set(UsageStats.milestone(words: words).previous, forKey: Self.milestoneKey)
  }

  // MARK: - Ledger watcher

  nonisolated private static func ledgerPath(_ config: AppConfig?) -> String {
    if let path = config?.usage.summaryPath, !path.isEmpty { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: CLIEnvironment.configDirectory(base: ProcessInfo.processInfo.environment, home: home))
      .appendingPathComponent("usage.json").path
  }

  /// Watches the ledger's directory: the CLI replaces the file atomically, so
  /// the file itself is a new inode after each write.
  private func watch(_ path: String, baseline: FileSignature?) {
    guard open, path != watchedPath else { return }
    stopWatching()
    let directory = (path as NSString).deletingLastPathComponent
    let fd = Darwin.open(directory, O_EVTONLY)
    guard fd >= 0 else {
      Log.write("stats: cannot watch \(directory) (errno \(errno)); refresh with the button")
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib, .link], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.ledgerEvent() }
    }
    source.setCancelHandler { close(fd) }
    watcher = source
    watchedPath = path
    ledgerSignature = baseline
    source.resume()
    // A write that landed after the read, before the watcher was up.
    ledgerEvent()
  }

  private func stopWatching() {
    watcher?.cancel()
    watcher = nil
    watchedPath = nil
    ledgerSignature = nil
  }

  private func ledgerEvent() {
    guard open, let path = watchedPath else { return }
    let signature = FileSignature(path: path)
    // Other files in the directory change too (history, cache).
    guard signature != ledgerSignature else { return }
    ledgerSignature = signature
    let delay = refresh.delayForChange(at: ProcessInfo.processInfo.systemUptime)
    debounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.reload() }
    }
    debounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
}

/// Enough of `stat` to tell that a file changed.
struct FileSignature: Equatable, Sendable {
  let inode: UInt64
  let size: Int64
  let modified: timespec

  init?(path: String) {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    inode = UInt64(info.st_ino)
    size = Int64(info.st_size)
    modified = info.st_mtimespec
  }

  static func == (lhs: FileSignature, rhs: FileSignature) -> Bool {
    lhs.inode == rhs.inode && lhs.size == rhs.size
      && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
  }
}
