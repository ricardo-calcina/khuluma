import AppKit
import KhulumaCore
import SwiftUI

/// Renders fixed data without starting capture, recovery, the CLI or a daemon.
@MainActor
enum StatsSnapshot {
  static func write(to directory: String) -> Int32 {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let updated = CivilDate("2026-10-14")!.noon
    var failures = 0
    func save(_ name: String, view: AnyView, width: CGFloat, height: CGFloat? = nil) {
      for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let file = url.appendingPathComponent("\(name)-\(look).png")
        if render(view, width: width, height: height, appearance: appearance, to: file) {
          print(file.path)
        } else {
          FileHandle.standardError.write(Data("snapshot failed: \(file.lastPathComponent)\n".utf8))
          failures += 1
        }
      }
    }
    let examples = fixtures(updated: updated)
    for (name, model) in examples {
      save("stats-\(name)", view: AnyView(StatsView(model: model)), width: 560)
    }
    do {
      let local = try UISettingsFixture().model()
      let cloud = try UISettingsFixture(provider: "elevenlabs", keyAvailable: true).model()
      let missingKey = try UISettingsFixture(provider: "elevenlabs").model()
      let full = examples[1].1
      for state in ["normal", "loading", "error", "recording"] {
        let menu = MenuModel()
        let stats: StatsModel
        switch state {
        case "loading": stats = StatsModel(stats: nil, updatedAt: nil)
        case "error":
          stats = StatsModel(stats: nil, updatedAt: nil, refreshFailed: true)
          menu.daemon = "Parakeet is unavailable. Open Settings to check the model."
        default: stats = full
        }
        if state == "recording" {
          menu.activity = "Recording…"
          menu.recording = true
        }
        save("menu-\(state)", view: AnyView(MenuPanel(
          model: menu, stats: stats, settings: local, openStats: {}, openSettings: {}, action: { _ in })
          .background(Color(nsColor: .windowBackgroundColor))), width: 400)
      }
      for (name, model) in [("local", local), ("cloud", cloud), ("key-missing", missingKey)] {
        save("settings-\(name)", view: AnyView(SettingsView(model: model)), width: 560, height: 634)
      }
      save("vocabulary", view: AnyView(VocabularyView(settings: local)), width: 560, height: 660)
      let navigation = AppNavigation()
      save("app-stats", view: AnyView(AppView(stats: full, settings: local, navigation: navigation)),
           width: 560, height: 634)
      save("app-stats-short", view: AnyView(AppView(stats: full, settings: local, navigation: navigation)),
           width: 560, height: 420)
      save("app-stats-milestone", view: AnyView(AppView(stats: examples[0].1, settings: local, navigation: navigation)),
           width: 560, height: 634)
      for (name, model) in [("normal", full), ("stale", examples.last!.1)] {
        save("usage-info-\(name)", view: AnyView(StatsDetailsView(model: model)), width: 292)
      }
      let settingsNavigation = AppNavigation()
      settingsNavigation.selection = .settings
      save("app-settings", view: AnyView(AppView(stats: full, settings: cloud, navigation: settingsNavigation)),
           width: 560, height: 634)
    } catch {
      FileHandle.standardError.write(Data("UI fixture failed: \(error.localizedDescription)\n".utf8))
      failures += 1
    }
    return failures == 0 ? 0 : 1
  }

  private static func render(_ view: AnyView, width: CGFloat, height: CGFloat?,
                             appearance: NSAppearance.Name, to file: URL) -> Bool {
    let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height ?? 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    window.setContentSize(hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    // Let SwiftUI commit its first frame.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: file)) != nil
  }

  fileprivate static func fixtures(updated: Date) -> [(String, StatsModel)] {
    let today = CivilDate("2026-10-14")!
    let full = report(today: today, trackedDays: 75, untracked: 0)
    let fullStats = UsageStats(report: full, today: today, firstWeekday: 2)
    return [
      ("90-days", StatsModel(stats: fullStats, updatedAt: updated, rangeDays: 90, celebrating: 50_000)),
      ("30-days", StatsModel(stats: fullStats, updatedAt: updated, rangeDays: 30)),
      ("incomplete", StatsModel(
        stats: UsageStats(report: report(today: today, trackedDays: 20, untracked: 12), today: today), updatedAt: updated)),
      ("unreadable", StatsModel(
        stats: UsageStats(report: report(today: today, trackedDays: 75, untracked: 0, status: "unreadable"),
                          today: today), updatedAt: updated)),
      ("lifetime-only", StatsModel(
        stats: UsageStats(report: report(today: today, trackedDays: 75, untracked: 0, status: nil),
                          today: today), updatedAt: updated)),
      ("not-started", StatsModel(
        stats: UsageStats(report: report(today: today, trackedDays: 0, untracked: 0, status: "not_started"), today: today),
        updatedAt: updated)),
      ("empty", StatsModel(
        stats: UsageStats(report: UsageReport(trackingStartedAt: nil, dictations: 0, words: 0, recordingMs: 0,
                                              fullElapsedMs: 0, typingWPM: 40, estimatedTimeDifferenceMs: 0,
                                              daily: daily(status: "not_started", today: today, days: [])),
                          today: today),
        updatedAt: updated)),
      ("refresh-failed", StatsModel(stats: fullStats, updatedAt: updated, refreshFailed: true)),
    ]
  }

  /// A plausible, repeatable history: busier on weekdays, some days off.
  private static func report(today: CivilDate, trackedDays: Int, untracked: Int,
                             status: String? = "active") -> UsageReport {
    var seed: UInt64 = 0x5EED
    func next(_ bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 33) % UInt64(bound))
    }
    var days: [UsageReport.Day] = []
    for offset in stride(from: trackedDays - 1, through: 0, by: -1) {
      let date = today.adding(days: -offset)
      let weekend = date.weekday == 1 || date.weekday == 7
      let roll = next(10)
      // Today has a little; a run of days up to it makes a streak.
      guard offset < 9 || roll >= (weekend ? 6 : 2) else { continue }
      let count = offset == 0 ? 3 : 1 + next(weekend ? 4 : 14)
      let words = count * (40 + next(90))
      let recording = Int(Double(words) / 165 * 60_000)
      days.append(UsageReport.Day(date: date, count: count, words: words, recordingMs: recording,
                                  fullElapsedMs: recording + count * 900,
                                  longestRecordingMs: recording / max(count, 1) * 2, mostWords: words / 2))
    }
    let dictations = days.reduce(0) { $0 + $1.count } + 80 + untracked
    let words = days.reduce(0) { $0 + $1.words } + 24_000
    let recording = days.reduce(0) { $0 + $1.recordingMs } + 8_000_000
    let elapsed = recording + dictations * 900
    let started = UsageReport.parseTimestamp("2026-07-19T06:30:53Z")
    return UsageReport(trackingStartedAt: started, dictations: dictations, words: words, recordingMs: recording,
                       fullElapsedMs: elapsed, typingWPM: 40,
                       estimatedTimeDifferenceMs: words * 60_000 / 40 - elapsed,
                       daily: status.map { daily(status: $0, today: today, days: days, untracked: untracked,
                                                 trackedDays: trackedDays) })
  }

  private static func daily(status: String, today: CivilDate, days: [UsageReport.Day], untracked: Int = 0,
                            trackedDays: Int = 0) -> UsageReport.Daily {
    UsageReport.Daily(status: status, startedAt: status == "active" ? today.adding(days: -(trackedDays - 1)).noon : nil,
                      asOfLocalDate: today, untrackedDeliveries: untracked, days: days)
  }
}

/// An in-memory copy of app-config. Only these sample values can be changed
/// by the preview; it never discovers a CLI or reads credentials/config files.
@MainActor
private struct UISettingsFixture {
  private var values: [String: Any]

  init(provider: String = "parakeet", keyAvailable: Bool = false) {
    values = [
      "schema_version": 1, "app_contract": AppContract.version, "cli_version": "preview",
      "hotkey": "ctrl+option+space", "sounds_enabled": true,
      "sounds": ["start": ["enabled": true, "path": NSNull()],
                 "cancel": ["enabled": true, "path": NSNull()]],
      "inline": ["autosend": true, "send_mode": "enter", "paste_target": "current",
                 "process_sound": true, "activate_delay_ms": 90, "send_delay_ms": 35],
      "cleanup": ["config_dir": "/private/tmp/khuluma-preview", "clean": "0", "repeats_level": "1",
                  "vocab_clean": "1", "british_spelling": "1", "locale_ctype": "", "locale_collate": ""],
      "transcription": ["provider": provider, "key_available": keyAvailable,
                        "socket_path": "/private/tmp/khuluma-preview/daemon.sock",
                        "model_path": "/private/tmp/khuluma-preview/parakeet-v3", "model_version": "v3",
                        "model_label": "Parakeet v3", "language": "en", "tail_pad_ms": "500",
                        "tail_rescue": true, "tail_rescue_ms": "", "tail_rescue_min_ms": "",
                        "keep_logs": false, "ffmpeg": true, "timeout_seconds": "600",
                        "processing_dir": "/private/tmp/khuluma-preview/processing"],
      "config": ["error": NSNull(), "source": "file"], "pipeline": ["supervise": false],
      "usage": ["summary_path": "/private/tmp/khuluma-preview/usage.json"],
    ]
  }

  func config() throws -> AppConfig {
    try AppContract.decodeAppConfig(JSONSerialization.data(withJSONObject: values))
  }

  func model() throws -> SettingsModel {
    let model = SettingsModel()
    model.preview = true
    model.loginStatus = .notRegistered
    model.adopt(try config())
    model.onOpenLog = { [weak model] in model?.message = "Preview: diagnostic logs are disabled." }
    model.onOpenConfig = { [weak model] in model?.message = "Preview settings are kept in memory." }
    installPreviewVocabulary(model)
    return model
  }

  mutating func save(_ key: String, value: String) throws {
    switch key {
    case "app.hotkey":
      _ = try HotkeySpec.parse(value)
      values["hotkey"] = value
    case "transcription.provider":
      guard ["parakeet", "elevenlabs"].contains(value) else { return }
      set("transcription", key: "provider", value: value)
    case "inline.autosend": set("inline", key: "autosend", value: value == "true")
    case "debug.keep_logs": set("transcription", key: "keep_logs", value: value == "true")
    case "clean.enabled": set("cleanup", key: "clean", value: value == "true" ? "1" : "0")
    case "clean.repeats_level": set("cleanup", key: "repeats_level", value: value)
    case "audio.sounds.enabled":
      values["sounds_enabled"] = value == "true"
      var sounds = values["sounds"] as! [String: [String: Any]]
      for name in Array(sounds.keys) { sounds[name]?["enabled"] = value == "true" }
      values["sounds"] = sounds
    default: break
    }
  }

  private mutating func set(_ section: String, key: String, value: Any) {
    var object = values[section] as! [String: Any]
    object[key] = value
    values[section] = object
  }
}

/// `-KhulumaUIPreview YES` provides the real controls with fixture data and
/// in-memory settings. No AppController, recorder, hotkey or runtime is made.
@MainActor
final class UIPreviewController: NSObject, NSApplicationDelegate {
  private let stats = StatsSnapshot.fixtures(updated: CivilDate("2026-10-14")!.noon)[1].1
  private var fixture = UISettingsFixture()
  private let settings = SettingsModel()
  private lazy var menu = StatusMenu(stats: stats, settings: settings, sampleData: true)
  private var appWindow: StatsWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    settings.preview = true
    settings.loginStatus = .notRegistered
    do { settings.adopt(try fixture.config()) }
    catch { NSApp.terminate(nil); return }
    settings.onSave = { [weak self] key, value in self?.save(key, value: value) }
    settings.onReload = { [weak self] in self?.settings.message = "Preview settings reloaded from memory." }
    settings.onOpenLog = { [weak self] in self?.settings.message = "Preview: diagnostic logs are disabled." }
    settings.onOpenConfig = { [weak self] in self?.settings.message = "Preview settings are kept in memory." }
    settings.onToggleLogin = { [weak self] in self?.settings.message = "Preview: Start at Login stays off." }
    installPreviewVocabulary(settings)
    menu.onShowStats = { [weak self] in self?.showWindow(settings: false) }
    menu.onShowSettings = { [weak self] in self?.showWindow(settings: true) }
    menu.install()
    if let directory = UserDefaults.standard.string(forKey: "KhulumaPreviewIconSnapshots") {
      let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.menu.writePreviewIconSnapshots(to: directory)
          NSApp.terminate(nil)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      return
    }
    showWindow(settings: false)
    if UserDefaults.standard.bool(forKey: "KhulumaPreviewMenu") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.menu.showPreviewMenu() }
    }
  }

  private func showWindow(settings selected: Bool) {
    let controller = appWindow ?? StatsWindowController(model: stats, settings: settings)
    appWindow = controller
    controller.window?.title = "Khuluma Preview · Sample Data"
    controller.show(settings: selected)
  }

  private func save(_ key: String, value: String) {
    do {
      try fixture.save(key, value: value)
      settings.adopt(try fixture.config())
      settings.finished()
      settings.message = "Preview setting saved in memory."
    } catch { settings.finished(error: error.localizedDescription) }
  }
}

/// Sample vocabulary remains in memory, including saves, reloads and imports.
private func installPreviewVocabulary(_ settings: SettingsModel) {
  final class Store {
    var snapshot = VocabularySnapshot(document: VocabularySheet(
      fillers: VocabularySheet.defaults.fillers,
      brands: [.init(heard: "Kaluma", write: "Khuluma"), .init(heard: "PN PM", write: "pnpm"),
               .init(heard: "X code", write: "Xcode")],
      words: [.init(heard: "core ml", write: "CoreML")]), revision: "preview")
  }
  let store = Store()
  settings.onLoadVocabulary = { store.snapshot }
  settings.onSaveVocabulary = { snapshot in
    store.snapshot = snapshot
    return snapshot
  }
}
