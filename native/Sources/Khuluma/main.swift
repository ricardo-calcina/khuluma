import AppKit
import KhulumaCore

let app = NSApplication.shared
if let directory = UserDefaults.standard.string(forKey: "KhulumaStatsSnapshot") {
  exit(MainActor.assumeIsolated { StatsSnapshot.write(to: directory) })
}
do {
  try AppRuntimePaths.prepareIsolation()
} catch {
  FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
  exit(2)
}
if UserDefaults.standard.bool(forKey: "KhulumaUIPreview") {
  guard AppRuntimePaths.isolated else {
    FileHandle.standardError.write(Data("UI preview requires private support, log and defaults overrides.\n".utf8))
    exit(2)
  }
  let controller = MainActor.assumeIsolated { UIPreviewController() }
  app.delegate = controller
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(controller) { app.run() }
} else {
  let controller = AppController()
  app.delegate = controller
  // SIGTERM/SIGINT (kill, logout scripts, Ctrl-C in a dev run) quit like
  // Quit: the normal drain runs, takes are saved and khulumad is stopped.
  // Handled off the main queue, and terminate runs from the main run loop:
  // called inside a main-queue drain, AppKit's wait for the drain's reply
  // would never see it.
  let quitSignals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { onMainRunLoop { MainActor.assumeIsolated { NSApp.terminate(nil) } } }
    source.resume()
    return source
  }
  // Menu-bar only (the bundle also sets LSUIElement).
  app.setActivationPolicy(.accessory)
  withExtendedLifetime((controller, quitSignals)) { app.run() }
}
