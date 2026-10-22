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
// Before anything reads or writes them: the Lowkey-era folders move to
// their Khuluma names (log, Application Support, timed-out takes).
if !AppRuntimePaths.isolated {
  LegacyPreferences.migrate()
  for line in LegacyNames.migrate() {
    Log.write("launch: " + line)
  }
}
let controller = AppController()
app.delegate = controller
// Menu-bar only (the bundle also sets LSUIElement).
app.setActivationPolicy(.accessory)
app.run()
