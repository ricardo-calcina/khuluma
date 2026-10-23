import AppKit
import Foundation
import KhulumaCore
import SwiftUI

/// Only exceptional status takes space in the menu's normal compact layout.
final class MenuModel: ObservableObject {
  @Published var activity: String?
  @Published var hotkey = "–"
  @Published var configWarning: String?
  @Published var recovered: String?
  @Published var canShowRecovered = false
  @Published var daemon: String?
  @Published var retry: String?
  @Published var paste: String?
  @Published var discard: String?
  @Published var unsaved: String?
  @Published var recording = false
}

/// A transient utility panel anchored to the status item.
final class StatusMenu: NSObject, NSPopoverDelegate {
  var onCancelRecording: () -> Void = {}
  var onRetryTimedOut: () -> Void = {}
  var onPasteRetried: () -> Void = {}
  var onDiscardTimedOut: () -> Void = {}
  var onDiscardUnsaved: () -> Void = {}
  var onShowRecovered: () -> Void = {}
  var onShowStats: () -> Void = {}
  var onShowSettings: () -> Void = {}
  var onWillOpen: () -> Void = {}

  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private let model: MenuModel
  private let stats: StatsModel
  private let settings: SettingsModel

  init(stats: StatsModel, settings: SettingsModel) {
    self.stats = stats
    self.settings = settings
    model = MenuModel()
    super.init()
  }

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    item.button?.target = self
    item.button?.action = #selector(togglePanel)
    item.button?.toolTip = "Khuluma"
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    popover.contentViewController = NSHostingController(rootView: MenuPanel(
      model: model, stats: stats, settings: settings,
      openStats: { [weak self] in self?.perform { self?.onShowStats() } },
      openSettings: { [weak self] in self?.perform { self?.onShowSettings() } },
      action: { [weak self] action in self?.perform { self?.run(action) } }))
    show(ActivityStatus(), recording: false)
  }

  @objc private func togglePanel() {
    if popover.isShown { popover.performClose(nil); return }
    guard let button = statusItem?.button else { return }
    onWillOpen()
    MainActor.assumeIsolated { stats.menuOpened() }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  func popoverDidClose(_ notification: Notification) {
    MainActor.assumeIsolated { stats.menuClosed() }
  }

  private func perform(_ action: () -> Void) {
    popover.performClose(nil)
    action()
  }

  private func run(_ action: MenuAction) {
    switch action {
    case .cancel: onCancelRecording()
    case .retry: onRetryTimedOut()
    case .paste: onPasteRetried()
    case .discard: onDiscardTimedOut()
    case .discardUnsaved: onDiscardUnsaved()
    case .recovered: onShowRecovered()
    case .quit: NSApp.terminate(nil)
    }
  }

  func show(_ status: ActivityStatus, recording: Bool) {
    model.activity = status.phase == .ready ? nil : status.title
    model.recording = recording
    let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "Khuluma")
    image?.isTemplate = true
    statusItem?.button?.image = image
  }

  func showHotkey(_ title: String) { model.hotkey = title.replacingOccurrences(of: "Hotkey: ", with: "") }
  func showConfigWarning(_ title: String?) { model.configWarning = title }
  func showRecovered(_ title: String, action: Bool) {
    model.recovered = title
    model.canShowRecovered = action
  }
  func showDaemon(_ title: String?) { model.daemon = title }
  func showTimedOut(retry: String?, paste: String?, discard: String?) {
    model.retry = retry; model.paste = paste; model.discard = discard
  }
  func showDiscardUnsaved(_ title: String?) { model.unsaved = title }
  func showLogin(_ status: LoginItem.Status) { settings.loginStatus = status }
}

enum MenuAction { case cancel, retry, paste, discard, discardUnsaved, recovered, quit }

struct MenuPanel: View {
  @ObservedObject var model: MenuModel
  @ObservedObject var stats: StatsModel
  @ObservedObject var settings: SettingsModel
  var openStats: () -> Void
  var openSettings: () -> Void
  var action: (MenuAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Khuluma", systemImage: "waveform").font(.headline)
        Spacer()
        Text("Today").font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 20) {
        metric("Words", value: todayWords)
        Divider()
        metric("Dictations", value: todayDictations)
        Divider()
        metric("Streak", value: stats.stats.map { "\($0.streak.current) day\($0.streak.current == 1 ? "" : "s")" } ?? "–")
      }
      .fixedSize(horizontal: false, vertical: true)
      if stats.refreshFailed {
        Label(stats.stats == nil ? "Couldn't load stats. Open Khuluma to retry." : "Couldn't refresh. Showing the last stats.",
              systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack(spacing: 12) {
        Button(action: openSettings) {
          Label(settings.modelTitle, systemImage: settings.provider == "elevenlabs" ? "cloud" : "desktopcomputer")
        }
        .help("Change transcription model")
        Spacer(minLength: 0)
        Button(action: openSettings) { Text(model.hotkey).monospaced() }
          .help("Change dictation shortcut")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      notices
      Divider()
      HStack {
        Button(action: openStats) { Label("Open Khuluma", systemImage: "macwindow") }
          .keyboardShortcut("o")
        Spacer()
        Button(action: openSettings) { Image(systemName: "gearshape") }
          .accessibilityLabel("Settings").help("Settings")
          .keyboardShortcut(",")
        Button { action(.quit) } label: { Image(systemName: "power") }
          .accessibilityLabel("Quit Khuluma").help("Quit Khuluma")
          .keyboardShortcut("q")
      }
      .buttonStyle(.borderless)
    }
    .padding(18)
    .frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var todayWords: String {
    guard let value = stats.stats else { return "–" }
    return value.hasDaily ? value.todayWords.formatted() : "–"
  }
  private var todayDictations: String {
    guard let value = stats.stats else { return "–" }
    return value.hasDaily ? value.todayDictations.formatted() : "–"
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var notices: some View {
    if settings.provider == "elevenlabs", settings.config?.transcription.keyAvailable == false {
      Label("ElevenLabs API key not found. Check Settings.", systemImage: "key")
        .font(.callout).foregroundStyle(.primary)
    }
    if let text = model.activity { Label(text, systemImage: model.recording ? "mic.fill" : "waveform").font(.callout) }
    ForEach([model.configWarning, model.daemon].compactMap { $0 }, id: \.self) { text in
      Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.primary)
    }
    if let text = model.recovered {
      if model.canShowRecovered { Button(text) { action(.recovered) } }
      else { Text(text).font(.callout).foregroundStyle(.secondary) }
    }
    if model.recording { Button("Cancel Recording") { action(.cancel) } }
    if let text = model.retry { Button(text) { action(.retry) } }
    if let text = model.paste { Button(text) { action(.paste) } }
    if let text = model.discard { Button(text) { action(.discard) } }
    if let text = model.unsaved { Button(text) { action(.discardUnsaved) } }
  }
}
