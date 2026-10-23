import AppKit
import Foundation
import KhulumaCore
import SwiftUI

/// Only exceptional status takes space in the menu's normal compact layout.
final class MenuModel: ObservableObject {
  @Published var activity: String?
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

/// A native status menu containing the compact SwiftUI utility view.
final class StatusMenu: NSObject {
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
  private var dropdown: StatusDropdownController?
  private let model: MenuModel
  private let stats: StatsModel
  private let settings: SettingsModel
  private let sampleData: Bool

  init(stats: StatsModel, settings: SettingsModel, sampleData: Bool = false) {
    self.stats = stats
    self.settings = settings
    self.sampleData = sampleData
    model = MenuModel()
    super.init()
  }

  func install() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    item.button?.toolTip = sampleData ? "Khuluma Preview · sample data" : "Khuluma"
    item.button?.setAccessibilityLabel(sampleData ? "Khuluma Preview" : "Khuluma")
    let dropdown = StatusDropdownController()
    let hosting = StatusMenuHostingView(rootView: MenuPanel(
      model: model, stats: stats, settings: settings,
      openStats: { [weak self] in self?.perform { self?.onShowStats() } },
      openSettings: { [weak self] in self?.perform { self?.onShowSettings() } },
      action: { [weak self] action in self?.perform { self?.run(action) } }, sampleData: sampleData))
    hosting.onSizeChange = { [weak dropdown] in dropdown?.fitToContent() }
    dropdown.setContent(hosting)
    dropdown.onOpen = { [weak self] in
      guard let self else { return }
      self.onWillOpen()
      MainActor.assumeIsolated { self.stats.menuOpened() }
    }
    dropdown.onClose = { [weak self] in
      MainActor.assumeIsolated { self?.stats.menuClosed() }
    }
    self.dropdown = dropdown
    item.menu = dropdown.menu
    show(ActivityStatus(), recording: false)
  }

  /// Exercise AppKit's normal menu opening in the isolated UI fixture.
  func showPreviewMenu() {
    guard sampleData else { return }
    statusItem?.button?.performClick(nil)
  }

  private func perform(_ action: () -> Void) {
    dropdown?.dismiss()
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
    let symbol = sampleData && status.phase == .ready ? "waveform" : status.symbol
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: sampleData ? "Khuluma Preview" : "Khuluma")
    image?.isTemplate = true
    statusItem?.button?.image = image
  }

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
  var sampleData = false
  @FocusState private var focusedFooter: FooterAction?

  private enum FooterAction: Hashable { case app, settings, quit }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(sampleData ? "Today · Preview" : "Today")
        .font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 20) {
        metric("Words", value: todayWords)
        metric("Dictations", value: todayDictations)
        metric("Streak", value: stats.stats.map { "\($0.streak.current) day\($0.streak.current == 1 ? "" : "s")" } ?? "–")
      }
      .fixedSize(horizontal: false, vertical: true)
      if stats.refreshFailed {
        Label(stats.stats == nil ? "Couldn't load stats. Open Khuluma to retry." : "Couldn't refresh. Showing the last stats.",
              systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
      }
      notices
      Divider()
      HStack(spacing: 8) {
        Button(action: openStats) { Image(systemName: "macwindow") }
          .accessibilityLabel("Open Khuluma").help("Open Khuluma")
          .keyboardShortcut("o")
          .focused($focusedFooter, equals: .app)
          .buttonStyle(MenuIconButtonStyle(focused: focusedFooter == .app))
        Spacer()
        Button(action: openSettings) { Image(systemName: "gearshape") }
          .accessibilityLabel("Settings").help("Settings")
          .keyboardShortcut(",")
          .focused($focusedFooter, equals: .settings)
          .buttonStyle(MenuIconButtonStyle(focused: focusedFooter == .settings))
        Button { action(.quit) } label: { Image(systemName: "power") }
          .accessibilityLabel("Quit Khuluma").help("Quit Khuluma")
          .keyboardShortcut("q")
          .focused($focusedFooter, equals: .quit)
          .buttonStyle(MenuIconButtonStyle(focused: focusedFooter == .quit))
      }
      .font(.system(size: 13))
      .foregroundStyle(.primary)
      .focusEffectDisabled()
    }
    .padding(16)
    .frame(width: 400)
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
      Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
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

private struct MenuIconButtonStyle: ButtonStyle {
  var focused: Bool

  func makeBody(configuration: Configuration) -> some View {
    Surface(configuration: configuration, focused: focused)
  }

  private struct Surface: View {
    let configuration: ButtonStyleConfiguration
    let focused: Bool
    // Keep source previews compatible with the Command Line Tools.
    @StateObject private var hover = Hover()

    var body: some View {
      configuration.label
        .frame(width: 32, height: 28)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .background {
          RoundedRectangle(cornerRadius: 5)
            .fill(configuration.isPressed
                  ? Color(nsColor: .tertiaryLabelColor)
                  : (hover.active ? Color(nsColor: .quaternaryLabelColor) : .clear))
        }
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .stroke(focused ? Color(nsColor: .keyboardFocusIndicatorColor) : .clear, lineWidth: 2)
        }
        .onHover { hover.active = $0 }
    }

    private final class Hover: ObservableObject {
      @Published var active = false
    }
  }
}
