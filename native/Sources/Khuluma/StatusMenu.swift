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
  private lazy var emblemRecordingImage = Self.templateImage(named: "KhulumaEmblemRecordingTemplate")
  private lazy var emblemFinishingImage = Self.templateImage(named: "KhulumaEmblemFinishingTemplate")
  private lazy var emblemFrameImage = Self.templateImage(named: "KhulumaEmblemFrameTemplate")
  private lazy var emblemRotorImage = Self.templateImage(named: "KhulumaEmblemRotorTemplate")
  private lazy var cursedFinishingFrames = Self.rotationFrames(rotor: finishingImage, center: NSPoint(x: 14, y: 10))
  private lazy var emblemFinishingFrames: [NSImage] = {
    guard let fixed = emblemFrameImage else { return [] }
    // Asset coordinates are top-origin (14, 12.417016); NSImage draws bottom-origin.
    return Self.rotationFrames(rotor: emblemRotorImage, fixed: fixed, center: NSPoint(x: 14, y: 7.582984))
  }()
  private var selectedRecordingImage: NSImage? { settings.iconTheme == .fullEmblem ? emblemRecordingImage : recordingImage }
  private var selectedFinishingImage: NSImage? { settings.iconTheme == .fullEmblem ? emblemFinishingImage : finishingImage }
  private var finishingFrames: [NSImage] { settings.iconTheme == .fullEmblem ? emblemFinishingFrames : cursedFinishingFrames }

  private static func rotationFrames(rotor: NSImage?, fixed: NSImage? = nil, center: NSPoint) -> [NSImage] {
    guard let rotor else { return [] }
    return (0..<96).map { index in
      let degrees = -Double(index) * 360 / 96
      // Cursed speech radius 9.675 pt and Full emblem radius 6.966 pt fit this canvas.
      // Capture immutable images/angle only: AppKit can draw this block later.
      let frame = NSImage(size: NSSize(width: 28, height: 20), flipped: false) { bounds in
        fixed?.draw(in: bounds)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -center.x, yBy: -center.y)
        transform.concat()
        rotor.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setFill()
        bounds.fill(using: .sourceIn)
        return true
      }
      frame.isTemplate = true
      return frame
    }
  }
  private var visibleStatus = ActivityStatus()
  private var visiblePhase: ActivityStatus.Phase = .ready
  private var finishingTimer: Timer?
  private var finishingStartedAt: TimeInterval?
  private var finishingFrame = 0
  private var displayOptionsObserver: NSObjectProtocol?
  private var previewReduceMotion: Bool?
  private var previewTimers: [Timer] = []

  private var reduceMotion: Bool {
    if sampleData, AppRuntimePaths.isolated, let previewReduceMotion { return previewReduceMotion }
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

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

  deinit {
    finishingTimer?.invalidate()
    previewTimers.forEach { $0.invalidate() }
    if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
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
    settings.onIconThemeChange = { [weak self] _ in
      guard let self else { return }
      self.show(self.visibleStatus, recording: self.model.recording)
    }
    displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil
    ) { [weak self] _ in
      RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.synchronizeFinishingMotion() }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    show(ActivityStatus(), recording: false)
  }

  private func synchronizeFinishingMotion() {
    guard visiblePhase == .processing, !reduceMotion, !finishingFrames.isEmpty else {
      finishingTimer?.invalidate()
      finishingTimer = nil
      finishingStartedAt = nil
      finishingFrame = 0
      if visiblePhase == .processing, let image = selectedFinishingImage { statusItem?.button?.image = image }
      return
    }
    guard finishingTimer == nil else { return }
    finishingStartedAt = ProcessInfo.processInfo.systemUptime
    finishingFrame = 0
    statusItem?.button?.image = finishingFrames[0]
    let timer = Timer(timeInterval: 1 / 24, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.advanceFinishingMotion() }
    }
    timer.tolerance = 0.005
    finishingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func advanceFinishingMotion() {
    // Read the preference here too: menu tracking must not defer Reduce Motion.
    guard visiblePhase == .processing, !reduceMotion, let finishingStartedAt else {
      synchronizeFinishingMotion()
      return
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - finishingStartedAt
    let frame = Int(elapsed.truncatingRemainder(dividingBy: 4) / 4 * 96)
    guard frame != finishingFrame else { return }
    finishingFrame = frame
    statusItem?.button?.image = finishingFrames[frame]
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
    let previousReduceMotion = previewReduceMotion
    let previousTheme = settings.iconTheme
    previewReduceMotion = true
    defer {
      button.appearance = previousAppearance
      button.highlight(false)
      previewReduceMotion = previousReduceMotion
      settings.selectIconTheme(previousTheme)
      show(ActivityStatus(), recording: false)
    }
    let resources = [("ready", readyImage), ("recording", recordingImage), ("processing", finishingImage),
                     ("emblem-recording", emblemRecordingImage), ("emblem-processing", emblemFinishingImage),
                     ("emblem-frame", emblemFrameImage), ("emblem-rotor", emblemRotorImage)]
    var failures = resources.filter { $0.1 == nil }.count
    for (name, image) in resources {
      print("icon resource \(name) loaded=\(image != nil) canvas=\(image?.size ?? .zero)")
    }
    for theme in StatusIconTheme.allCases {
      settings.selectIconTheme(theme)
      let restored = SettingsModel().iconTheme == theme
      if !restored { failures += 1 }
      print("icon theme \(theme.rawValue) privateDefaultsRoundtrip=\(restored)")
      let themedOutput = output.appendingPathComponent(theme.rawValue, isDirectory: true)
      do { try FileManager.default.createDirectory(at: themedOutput, withIntermediateDirectories: true) }
      catch { failures += 1; continue }
      for (name, activity, recording) in states {
        show(activity, recording: recording)
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
          button.appearance = NSAppearance(named: appearance)
          for selected in [false, true] {
            func capture() {
              let file = themedOutput.appendingPathComponent("icon-\(name)-\(look)\(selected ? "-selected" : "").png")
              if self.capturePreviewButton(to: file) == nil { failures += 1 }
              if self.statusItem?.length != 36 || button.image?.isTemplate != true { failures += 1 }
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
    }
    print("icon snapshots complete: \(failures) failures")
  }

  private func capturePreviewButton(to file: URL) -> Data? {
    guard sampleData, AppRuntimePaths.isolated, let button = statusItem?.button else { return nil }
    button.displayIfNeeded()
    let bounds = button.bounds
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = bounds.size
    button.cacheDisplay(in: bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: file)) != nil else { return nil }
    print("\(file.path) uptime=\(ProcessInfo.processInfo.systemUptime) theme=\(settings.iconTheme.rawValue) phase=\(visiblePhase) frame=\(finishingFrame) angle=\(Double(finishingFrame) * 360 / 96) timer=\(finishingTimer?.isValid == true) slot=\(statusItem?.length ?? 0) window=\(button.window?.frame ?? .zero) button=\(button.frame) image=\(button.image?.size ?? .zero) template=\(button.image?.isTemplate == true) menuOpen=\(dropdown?.isPresented == true) label=\(button.accessibilityLabel() ?? "")")
    return png
  }

  private static func previewEyePixels(_ png: Data) -> Data? {
    guard let bitmap = NSBitmapImageRep(data: png), !bitmap.isPlanar,
          bitmap.bitsPerPixel == 32, bitmap.bitsPerSample == 8, bitmap.hasAlpha,
          bitmap.pixelsWide >= 56, let bytes = bitmap.bitmapData else { return nil }
    // The rotating seal stays inside canvas x7.034…20.966pt. These outer
    // strips include both stationary eyes and exclude every rotor angle.
    let canvasLeft = (bitmap.pixelsWide - 56) / 2
    let leftEnd = canvasLeft + 12
    let rightStart = canvasLeft + 44
    let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    var pixels = Data()
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide where x < leftEnd || x >= rightStart {
        pixels.append(bytes[y * bitmap.bytesPerRow + x * 4 + alpha])
      }
    }
    return pixels
  }

  /// Actual elapsed-time motion, including native menu tracking; private fixtures only.
  func writePreviewAnimationSnapshots(to directory: String, completion: @escaping () -> Void) {
    guard sampleData, AppRuntimePaths.isolated else { completion(); return }
    let previousTheme = settings.iconTheme
    settings.selectIconTheme(.cursedSpeech)
    writePreviewAnimationTheme(to: directory + "/cursed-speech") { [weak self] in
      guard let self else { completion(); return }
      self.settings.selectIconTheme(.fullEmblem)
      self.writePreviewAnimationTheme(to: directory + "/full-emblem") { [weak self] in
        self?.settings.selectIconTheme(previousTheme)
        completion()
      }
    }
  }

  private func writePreviewAnimationTheme(to directory: String, completion: @escaping () -> Void) {
    guard sampleData, AppRuntimePaths.isolated, let button = statusItem?.button else { completion(); return }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    catch { print("animation snapshots failed: \(error.localizedDescription)"); completion(); return }
    let theme = settings.iconTheme
    let previousReduceMotion = previewReduceMotion
    var processing = ActivityStatus(); processing.processingStarted()
    var recording = ActivityStatus(); recording.recordingStarted()
    var error = ActivityStatus(); error.failed("Preview error")
    let checks = [("ready", ActivityStatus(), false, false), ("recording", recording, true, false),
                  ("error", error, false, false), ("reduce-motion", processing, false, false),
                  ("motion-resumed", processing, false, true)]
    var failures = [readyImage, selectedRecordingImage, selectedFinishingImage].filter { $0 == nil }.count
    var index = 0
    var pictures = Set<Data>()
    var openFrames = Set<Int>()
    var closedFrames = Set<Int>()
    var firstPicture: Data?
    var firstFrame = 0
    var eyePixels: Data?
    var eyesStable = true
    var eyeSamples = 0
    previewReduceMotion = false
    show(processing, recording: false)
    let began = finishingStartedAt
    let windowSize = button.window?.frame.size
    let timer = Timer(timeInterval: 1 / 12, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self else { timer.invalidate(); completion(); return }
        if index < 49 {
          if let png = self.capturePreviewButton(to: output.appendingPathComponent(String(format: "processing-%03d.png", index))) {
            pictures.insert(png)
            if theme == .fullEmblem {
              if let pixels = Self.previewEyePixels(png), pixels.contains(where: { $0 != 0 }) {
                if let eyePixels, eyePixels != pixels { eyesStable = false }
                eyePixels = pixels
                eyeSamples += 1
              } else { eyesStable = false }
            }
          } else { failures += 1 }
          if self.dropdown?.isPresented == true { openFrames.insert(self.finishingFrame) }
          else { closedFrames.insert(self.finishingFrame) }
          if index == 6 {
            self.show(processing, recording: false)
            if self.finishingStartedAt != began { failures += 1 }
            print("animation repeated Processing preservedStart=\(self.finishingStartedAt == began)")
          }
          if index == 10 {
            let before = self.capturePreviewButton(to: output.appendingPathComponent("theme-switch-before.png"))
            let frame = self.finishingFrame
            self.settings.selectIconTheme(theme == .cursedSpeech ? .fullEmblem : .cursedSpeech)
            let alternate = self.capturePreviewButton(to: output.appendingPathComponent("theme-switch-alternate.png"))
            let preserved = self.finishingStartedAt == began && self.finishingFrame == frame
            if !preserved || before == nil || alternate == nil || before == alternate { failures += 1 }
            self.settings.selectIconTheme(theme)
            let restored = self.capturePreviewButton(to: output.appendingPathComponent("theme-switch-restored.png"))
            if self.finishingStartedAt != began || self.finishingFrame != frame || restored != before { failures += 1 }
            print("animation theme switch preservedStartAndFrame=\(preserved) restoredPixels=\(restored == before)")
          }
        } else {
          let step = (index - 49) / 8
          let offset = (index - 49) % 8
          if step == checks.count {
            if pictures.count < 10 || openFrames.count < 3 || closedFrames.count < 3 { failures += 1 }
            if theme == .fullEmblem, !eyesStable || eyeSamples < 40 { failures += 1 }
            self.previewTimers.forEach { $0.invalidate() }; self.previewTimers = []
            self.dropdown?.dismiss()
            self.previewReduceMotion = previousReduceMotion
            self.show(ActivityStatus(), recording: false)
            print("animation snapshots complete: \(failures) failures; theme=\(theme.rawValue) motionPictures=\(pictures.count) menuOpenFrames=\(openFrames.count) menuClosedFrames=\(closedFrames.count) stationaryEyes=\(eyesStable) eyeSamples=\(eyeSamples)")
            completion()
            return
          }
          let check = checks[step]
          if offset == 0 {
            self.previewReduceMotion = step == 4
            self.show(processing, recording: false)
          }
          if offset == 3 {
            self.previewReduceMotion = step == 3
            if step >= 3 {
              NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
            } else { self.show(check.1, recording: check.2) }
          }
          if offset == (step >= 3 ? 4 : 3) {
            firstFrame = self.finishingFrame
            firstPicture = self.capturePreviewButton(to: output.appendingPathComponent("\(check.0)-before.png"))
          }
          if offset == 7 {
            let after = self.capturePreviewButton(to: output.appendingPathComponent("\(check.0)-after.png"))
            let frameChanged = self.finishingFrame != firstFrame
            let pixelsChanged = after != firstPicture
            let running = self.finishingTimer?.isValid == true
            if firstPicture == nil || after == nil || frameChanged != check.3 || pixelsChanged != check.3 || running != check.3 { failures += 1 }
            print("animation check \(check.0) frameChanged=\(frameChanged) pixelsChanged=\(pixelsChanged) timer=\(running) expectedMotion=\(check.3)")
          }
        }
        if self.statusItem?.length != 36 || button.window?.frame.size != windowSize || button.image?.isTemplate != true { failures += 1 }
        index += 1
      }
    }
    let open = Timer(timeInterval: 1, repeats: false) { [weak self] _ in self?.statusItem?.button?.performClick(nil) }
    let close = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.dropdown?.dismiss() }
    previewTimers = [timer, open, close]
    previewTimers.forEach { RunLoop.main.add($0, forMode: .common) }
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
    visibleStatus = status
    visiblePhase = status.phase
    synchronizeFinishingMotion()
    let customImage: NSImage?
    switch status.phase {
    case .ready: customImage = readyImage
    case .recording: customImage = selectedRecordingImage
    case .processing: customImage = finishingTimer == nil ? selectedFinishingImage : finishingFrames[finishingFrame]
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
        // The period is chosen in Settings → Appearance; the labels name it.
        HStack(spacing: 12) {
          metric(today ? "Words today" : "Total words", value: figures.map { $0.words.formatted() } ?? "–")
          metric(today ? "Saved today" : "Time saved", value: timeSaved)
            .help("Estimated time saved compared with typing at \(stats.stats?.lifetime.typingWPM ?? 40) words per minute, including delivery time.")
          metric(today ? "WPM today" : "Average WPM", value: figures?.wordsPerMinute.map { $0.formatted() } ?? "–")
            .help("Words per minute of recording, including pauses.")
        }
        .fixedSize(horizontal: false, vertical: true)
        if settings.menuShowsWeek, let days = stats.stats?.lastDays(7), stats.stats?.hasDaily == true {
          WeekBars(days: days)
        }
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
        Toggle("Auto-send", isOn: Binding(
          get: { settings.config?.inline.autosend ?? false },
          set: { settings.save("inline.autosend", $0 ? "true" : "false") }))
          .toggleStyle(.switch).controlSize(.mini)
          .font(.caption).foregroundStyle(.secondary)
          .disabled(!settings.editable)
          .help(autosendHelp)
          .padding(.trailing, 4)
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

  private var autosendHelp: String {
    guard let shortcut = settings.pasteOnlyShortcut else { return "Paste, then press your send key." }
    return "Paste, then press your send key. Finish with \(shortcut.display) to paste one take without sending."
  }

  private var today: Bool { settings.menuFigures == .today }
  private var figures: UsageStats.Figures? { stats.stats?.figures(settings.menuFigures) }

  private var timeSaved: String {
    guard let figures, figures.words > 0 else { return "–" }
    return Format.savedTime(ms: figures.estimatedSavedMs)
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(spacing: 3) {
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

/// Words per day for the last week, today on the right and emphasised.
private struct WeekBars: View {
  let days: [UsageStats.Cell]

  var body: some View {
    let peak = max(days.map(\.words).max() ?? 0, 1)
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(Array(days.enumerated()), id: \.offset) { index, day in
        let isToday = index == days.count - 1
        VStack(spacing: 3) {
          ZStack(alignment: .bottom) {
            Capsule().fill(Color(nsColor: .quaternaryLabelColor)).frame(height: 2)
            if day.words > 0 {
              RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(isToday ? 1 : 0.6))
                .frame(height: max(3, 22 * CGFloat(day.words) / CGFloat(peak)))
            }
          }
          .frame(height: 22, alignment: .bottom)
          Text(Self.initial(day.date))
            .font(.system(size: 9, weight: isToday ? .semibold : .regular))
            .foregroundStyle(isToday ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(day.state == .untracked ? "Not tracked" : "\(day.words.formatted()) words")
      }
    }
    .padding(.horizontal, 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Last 7 days: " + days.map { "\(Self.initial($0.date)) \($0.words) words" }.joined(separator: ", "))
  }

  private static func initial(_ date: CivilDate) -> String {
    ["S", "M", "T", "W", "T", "F", "S"][(date.weekday - 1) % 7]
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
