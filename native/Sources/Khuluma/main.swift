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
  // Menu-bar only (the bundle also sets LSUIElement).
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(controller) { app.run() }
}
