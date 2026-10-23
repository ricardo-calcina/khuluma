import AppKit
import SwiftUI
import KhulumaCore

/// The one stats window, kept for reuse. Khuluma has no main menu (it's a
/// menu-bar app), so Escape and ⌘W are handled by the window itself.
@MainActor
final class StatsWindowController: NSWindowController, NSWindowDelegate {
  private let model: StatsModel
  private let navigation = AppNavigation()

  init(model: StatsModel, settings: SettingsModel) {
    self.model = model
    let window = StatsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 670),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Khuluma"
    window.isReleasedWhenClosed = false
    let hosting = NSHostingController(rootView: AppView(stats: model, settings: settings, navigation: navigation))
    window.contentViewController = hosting
    window.setContentSize(NSSize(width: 600, height: 670))
    window.contentMinSize = NSSize(width: 600, height: 460)
    window.center()
    // AppKit frame autosave uses the app's standard defaults domain rather
    // than our isolated suite. A fixture instance must not write daily state.
    if !AppRuntimePaths.isolated { window.setFrameAutosaveName("KhulumaStats") }
    window.appearance = Self.forcedAppearance
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// `-KhulumaStatsAppearance light|dark` forces the window's appearance, to
  /// check both without changing the system setting.
  static var forcedAppearance: NSAppearance? {
    switch AppRuntimePaths.defaults.string(forKey: "KhulumaStatsAppearance") {
    case "light": return NSAppearance(named: .aqua)
    case "dark": return NSAppearance(named: .darkAqua)
    default: return nil
    }
  }

  func show(settings: Bool = false) {
    navigation.selection = settings ? .settings : .stats
    NSApp.activate()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    // Not left to becoming key: activation can be refused, and the window
    // then shows without ever becoming key.
    model.windowOpened()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    model.windowBecameKey()
  }

  func windowWillClose(_ notification: Notification) {
    model.windowClosed()
  }
}

@MainActor
final class AppNavigation: ObservableObject {
  enum Page { case stats, settings }
  @Published var selection: Page = .stats
}

struct AppView: View {
  @ObservedObject var stats: StatsModel
  @ObservedObject var settings: SettingsModel
  @ObservedObject var navigation: AppNavigation

  var body: some View {
    VStack(spacing: 0) {
      Picker("Khuluma", selection: $navigation.selection) {
        Text("Stats").tag(AppNavigation.Page.stats)
        Text("Settings").tag(AppNavigation.Page.settings)
      }
      .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(16)
      Divider()
      if navigation.selection == .stats {
        ScrollView {
          StatsView(model: stats).frame(maxWidth: .infinity)
        }
      } else {
        SettingsView(model: settings)
      }
    }
    .frame(minWidth: 600, minHeight: 460)
    .background(Color(nsColor: .windowBackgroundColor))
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
