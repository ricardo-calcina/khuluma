import AppKit
import ImageIO
import KhulumaCore
import UniformTypeIdentifiers

/// `-KhulumaPreviewMenuSnapshots <dir>` in the isolated UI preview: opens the
/// real native menu with its inline microphone list and sample inputs, in light
/// and dark, and saves the app's own menu windows as PNGs (playbook §5).
@MainActor
final class MenuSnapshots {
  private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
  /// Unavailable to Swift in the current SDK, but still exported; own windows need no permission.
  private static let createImage: CreateImage? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(symbol, to: CreateImage.self)
  }()

  private let menu: StatusMenu
  private let settings: SettingsModel
  private let output: URL
  private var timers: [Timer] = []
  private var failures = 0

  init(menu: StatusMenu, settings: SettingsModel, directory: String) {
    self.menu = menu
    self.settings = settings
    output = URL(fileURLWithPath: directory, isDirectory: true)
  }

  func run(completion: @escaping () -> Void) {
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let states: [(String, AudioInput?)] = [("default", nil), ("chosen", PreviewInputs.display), ("missing", PreviewInputs.missing)]
    var time = 0.5
    // Each step is its own one-shot timer: opening a menu blocks in its
    // tracking loop, and the next steps must still fire inside it.
    func at(_ delay: Double, _ body: @escaping () -> Void) {
      let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
      timers.append(timer)
      RunLoop.main.add(timer, forMode: .common)
    }
    let deviceSets: [(String, AudioInputs)] = [("2dev", PreviewInputs.connected), ("3dev", PreviewInputs.three)]
    for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      for (devices, inputs) in deviceSets {
      for (state, choice) in states {
        let name = "\(state)-\(devices)-\(look)"
        at(time) { [self] in
          NSApp.appearance = NSAppearance(named: appearance)
          menu.setPreviewAppearance(NSAppearance(named: appearance))
          settings.adoptAudioInputs(inputs)
          settings.selectMicrophone(choice)
        }
        at(time + 0.1) { [self] in menu.showPreviewMenu() }
        at(time + 0.4) { [self] in if !menu.previewMenuIsOpen { print("\(name): reopening"); menu.showPreviewMenu() } }
        at(time + 0.8) { [self] in capture("menu-\(name)") }
        if state == "default", devices == "2dev" {
          // Live update while open: AirPods connect and become the default.
          at(time + 1.0) { [self] in settings.adoptAudioInputs(PreviewInputs.withAirPods) }
          at(time + 1.1) { [self] in capture("menu-default-live-soon-\(look)") }
          at(time + 1.6) { [self] in capture("menu-default-live-\(look)") }
        }
        at(time + 2.0) { [self] in menu.dismissPreviewMenu() }
        time += 2.4
      }
      }
      // Recording: the activity label and Cancel Recording share one row.
      at(time) { [self] in
        settings.selectMicrophone(nil)
        var recording = ActivityStatus(); recording.recordingStarted()
        menu.show(recording, recording: true)
      }
      at(time + 0.1) { [self] in menu.showPreviewMenu() }
      at(time + 0.8) { [self] in capture("menu-recording-\(look)") }
      at(time + 1.0) { [self] in menu.dismissPreviewMenu(); menu.show(ActivityStatus(), recording: false) }
      time += 1.4
      // The menu before this change, for comparing separators and spacing.
      at(time) { [self] in
        settings.adoptAudioInputs(PreviewInputs.connected)
        guard let baseline = menu.previewBaselineMenu() else { return }
        baseline.appearance = NSAppearance(named: appearance)
        openPopUp = baseline
        baseline.popUp(positioning: nil, at: NSPoint(x: 200, y: NSScreen.main.map { $0.visibleFrame.maxY - 40 } ?? 800), in: nil)
      }
      at(time + 0.7) { [self] in capture("baseline-\(look)") }
      at(time + 0.9) { [self] in openPopUp?.cancelTracking(); openPopUp = nil }
      time += 1.3
    }
    at(time) { [self] in
      settings.selectMicrophone(nil)
      NSApp.appearance = nil
      menu.setPreviewAppearance(nil)
      print("menu snapshots complete: \(failures) failures")
      completion()
    }
  }

  private var openPopUp: NSMenu?

  private func capture(_ name: String) {
    guard let createImage = Self.createImage else { failures += 1; print("capture unavailable"); return }
    let pid = ProcessInfo.processInfo.processIdentifier
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
      .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
      .compactMap { info -> (UInt32, CGFloat)? in
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let height = bounds["Height"], height > 60 else { return nil }
        return (id, bounds["Width"] ?? 0)
      }
    guard !windows.isEmpty else {
      failures += 1
      let all = (CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        .map { "\($0[kCGWindowBounds as String] ?? "") onscreen=\($0[kCGWindowIsOnscreen as String] ?? "-") layer=\($0[kCGWindowLayer as String] ?? "")" }
      print("\(name): no menu window; open=\(menu.previewMenuIsOpen) windows=\(all)")
      return
    }
    for (index, window) in windows.enumerated() {
      // optionIncludingWindow = 8; boundsIgnoreFraming | bestResolution = 1 | 8.
      guard let image = createImage(.null, 8, window.0, 1 | 8)?.takeRetainedValue() else { failures += 1; continue }
      let file = output.appendingPathComponent(windows.count == 1 ? "\(name).png" : "\(name)-\(index).png")
      guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        failures += 1; continue
      }
      CGImageDestinationAddImage(destination, image, nil)
      if CGImageDestinationFinalize(destination) { print("\(file.path) width=\(window.1)") } else { failures += 1 }
    }
  }
}
