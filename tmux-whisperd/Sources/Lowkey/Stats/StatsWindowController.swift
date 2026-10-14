import AppKit
import SwiftUI

/// The one stats window, kept for reuse. Lowkey has no main menu (it's a
/// menu-bar app), so Escape and ⌘W are handled by the window itself.
@MainActor
final class StatsWindowController: NSWindowController, NSWindowDelegate {
  private let model: StatsModel

  init(model: StatsModel) {
    self.model = model
    let window = StatsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Lowkey Stats"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 480, height: 400)
    window.contentViewController = NSHostingController(rootView: StatsView(model: model))
    window.setContentSize(NSSize(width: 560, height: 640))
    window.center()
    window.setFrameAutosaveName("LowkeyStats")
    window.appearance = Self.forcedAppearance
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// `-LowkeyStatsAppearance light|dark` forces the window's appearance, to
  /// check both without changing the system setting.
  static var forcedAppearance: NSAppearance? {
    switch UserDefaults.standard.string(forKey: "LowkeyStatsAppearance") {
    case "light": return NSAppearance(named: .aqua)
    case "dark": return NSAppearance(named: .darkAqua)
    default: return nil
    }
  }

  func show() {
    // Becoming key reloads; a window that already is key doesn't become it again.
    let wasKey = window?.isKeyWindow == true
    NSApp.activate()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    if wasKey {
      model.windowOpened()
    }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    model.windowOpened()
  }

  func windowWillClose(_ notification: Notification) {
    model.windowClosed()
  }
}

private final class StatsWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.charactersIgnoringModifiers == "w" {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
