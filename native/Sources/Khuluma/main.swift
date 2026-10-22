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
let controller = AppController()
app.delegate = controller
// Menu-bar only (the bundle also sets LSUIElement).
app.setActivationPolicy(.accessory)
app.run()
