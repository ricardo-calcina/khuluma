import AppKit

/// The menu bar shown while Khuluma is a regular app (its window is open).
@MainActor
enum AppMainMenu {
  private final class Target: NSObject {
    let openSettings: () -> Void
    init(openSettings: @escaping () -> Void) { self.openSettings = openSettings }
    @objc func settings(_ sender: Any?) { openSettings() }
  }
  private static var target: Target?

  static func install(openSettings: @escaping () -> Void) {
    let target = Target(openSettings: openSettings)
    self.target = target
    let main = NSMenu()

    let app = NSMenu(title: "Khuluma")
    app.addItem(withTitle: "About Khuluma",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(.separator())
    let settings = app.addItem(withTitle: "Settings…", action: #selector(Target.settings(_:)), keyEquivalent: ",")
    settings.target = target
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Khuluma", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Khuluma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    add(app, to: main)

    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
      .keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    add(edit, to: main)

    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    add(window, to: main)

    NSApp.mainMenu = main
    NSApp.windowsMenu = window
  }

  private static func add(_ menu: NSMenu, to main: NSMenu) {
    let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
    item.submenu = menu
    main.addItem(item)
  }
}
