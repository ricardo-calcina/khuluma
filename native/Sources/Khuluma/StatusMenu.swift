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
  private lazy var readyImage = Self.templateImage(named: "KhulumaMenuTemplate")
  private lazy var recordingImage = Self.templateImage(named: "KhulumaRecordingTemplate")
  private lazy var finishingImage = Self.templateImage(named: "KhulumaFinishingTemplate")

  private static func templateImage(named name: String) -> NSImage? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
          let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 28, height: 20)
    image.isTemplate = true
    return image
  }

  init(stats: StatsModel, settings: SettingsModel, sampleData: Bool = false) {
    self.stats = stats
    self.settings = settings
    self.sampleData = sampleData
    model = MenuModel()
    super.init()
  }

  func install() {
    // The 28-point artwork canvas needs side padding; keep activity states in
    // the same slot so neighbouring menu items never move during a take.
    let item = NSStatusBar.system.statusItem(withLength: 36)
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

  /// Cache the real AppKit button, without changing the Mac's appearance.
  func writePreviewIconSnapshots(to directory: String) {
    guard sampleData, AppRuntimePaths.isolated, let button = statusItem?.button else { return }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    catch { print("icon snapshots failed: \(error.localizedDescription)"); return }
    var status = ActivityStatus()
    var states = [("ready", status, false)]
    status.recordingStarted(); states.append(("recording", status, true))
    status.recordingCancelled(); status.processingStarted(); states.append(("processing", status, false))
    status.failed("Preview error"); states.append(("error", status, false))
    let previousAppearance = button.appearance
    defer {
      button.appearance = previousAppearance
      button.highlight(false)
      show(ActivityStatus(), recording: false)
    }
    let resources = [("ready", readyImage), ("recording", recordingImage), ("processing", finishingImage)]
    var failures = resources.filter { $0.1 == nil }.count
    for (name, image) in resources {
      print("icon resource \(name) loaded=\(image != nil) canvas=\(image?.size ?? .zero)")
    }
    for (name, activity, recording) in states {
      show(activity, recording: recording)
      for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        button.appearance = NSAppearance(named: appearance)
        for selected in [false, true] {
          func capture() {
            button.displayIfNeeded()
            let bounds = button.bounds
            let file = output.appendingPathComponent("icon-\(name)-\(look)\(selected ? "-selected" : "").png")
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
              pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
              bytesPerRow: 0, bitsPerPixel: 0) else { failures += 1; return }
            bitmap.size = bounds.size
            button.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]),
                  (try? png.write(to: file)) != nil else { failures += 1; return }
            let image = button.image
            if self.statusItem?.length != 36 || image?.isTemplate != true { failures += 1 }
            print("\(file.path) slot=\(self.statusItem?.length ?? 0) window=\(button.window?.frame ?? .zero) button=\(button.frame) image=\(image?.size ?? .zero) template=\(image?.isTemplate == true) menuOpen=\(self.dropdown?.isPresented == true) label=\(button.accessibilityLabel() ?? "")")
          }
          if selected {
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
              MainActor.assumeIsolated { capture(); self?.dropdown?.dismiss() }
            }
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            timer.invalidate()
          } else { capture() }
        }
      }
    }
    print("icon snapshots complete: \(failures) failures")
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
    let name = sampleData ? "Khuluma Preview" : "Khuluma"
    let symbol = sampleData && status.phase == .ready ? "waveform" : status.symbol
    let customImage: NSImage?
    switch status.phase {
    case .ready: customImage = readyImage
    case .recording: customImage = recordingImage
    case .processing: customImage = finishingImage
    case .error: customImage = nil
    }
    let image = customImage ?? NSImage(systemSymbolName: symbol, accessibilityDescription: name)
    image?.isTemplate = true
    statusItem?.button?.image = image
    statusItem?.button?.setAccessibilityLabel("\(name) · \(status.title)")
    statusItem?.button?.toolTip = "\(name) · \(status.title)" + (sampleData ? " · sample data" : "")
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        Text(sampleData ? "All time · Preview" : "All time")
          .font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
        HStack(spacing: 12) {
          metric("Total words", value: stats.stats.map { $0.lifetime.words.formatted() } ?? "–")
          metric("Time saved", value: timeSaved)
            .help("Estimated time saved compared with typing at \(stats.stats?.lifetime.typingWPM ?? 40) words per minute, including delivery time.")
          metric("Average WPM", value: stats.stats?.lifetime.wordsPerMinute.map { $0.formatted() } ?? "–")
            .help("Words per minute of recording, including pauses.")
        }
        .fixedSize(horizontal: false, vertical: true)
        if stats.refreshFailed {
          Label(stats.stats == nil ? "Couldn't load stats. Open Khuluma to retry." : "Couldn't refresh. Showing the last stats.",
                systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        }
        notices
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      Divider()
      HStack(spacing: 8) {
        Button(action: openStats) { Image(systemName: "macwindow") }
          .accessibilityLabel("Open Khuluma").help("Open Khuluma")
          .keyboardShortcut("o")
        Spacer()
        Button(action: openSettings) { Image(systemName: "gearshape") }
          .accessibilityLabel("Settings").help("Settings")
          .keyboardShortcut(",")
        Button { action(.quit) } label: { Image(systemName: "power") }
          .accessibilityLabel("Quit Khuluma").help("Quit Khuluma")
          .keyboardShortcut("q")
      }
      .font(.system(size: 12))
      .foregroundStyle(.primary)
      .buttonStyle(MenuIconButtonStyle())
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
    }
    .frame(width: 400)
  }

  private var timeSaved: String {
    guard let lifetime = stats.stats?.lifetime, lifetime.words > 0 else { return "–" }
    return Format.savedTime(ms: lifetime.estimatedSavedMs)
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
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
  func makeBody(configuration: Configuration) -> some View {
    Surface(configuration: configuration)
  }

  private struct Surface: View {
    let configuration: ButtonStyleConfiguration
    // Keep source previews compatible with the Command Line Tools.
    @StateObject private var hover = Hover()

    var body: some View {
      configuration.label
        .frame(width: 28, height: 24)
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .background {
          RoundedRectangle(cornerRadius: 5)
            .fill(configuration.isPressed
                  ? Color(nsColor: .tertiaryLabelColor)
                  : (hover.active ? Color(nsColor: .quaternaryLabelColor) : .clear))
        }
        .onHover { hover.active = $0 }
    }

    private final class Hover: ObservableObject {
      @Published var active = false
    }
  }
}
