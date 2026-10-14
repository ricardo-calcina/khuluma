import AppKit

let app = NSApplication.shared
if let directory = UserDefaults.standard.string(forKey: "LowkeyStatsSnapshot") {
  exit(MainActor.assumeIsolated { StatsSnapshot.write(to: directory) })
}
let controller = AppController()
app.delegate = controller
// Menu-bar only (the bundle also sets LSUIElement).
app.setActivationPolicy(.accessory)
app.run()
