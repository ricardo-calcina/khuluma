import AppKit
import SwiftUI
import KhulumaCore

/// Stats is the home screen. Settings lives behind the native toolbar gear.
@MainActor
final class StatsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  private let model: StatsModel
  private let navigation = AppNavigation()
  private let detailsPopover = NSPopover()
  private static let settingsItem = NSToolbarItem.Identifier("Khuluma.Settings")
  private static let refreshItem = NSToolbarItem.Identifier("Khuluma.Refresh")
  private static let infoItem = NSToolbarItem.Identifier("Khuluma.UsageInfo")
  private static let backItem = NSToolbarItem.Identifier("Khuluma.Back")

  init(model: StatsModel, settings: SettingsModel) {
    self.model = model
    let window = StatsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 634),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Khuluma"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: AppView(
      stats: model, settings: settings, navigation: navigation))
    window.setContentSize(NSSize(width: 560, height: 634))
    window.contentMinSize = NSSize(width: 560, height: 420)
    window.center()
    if !AppRuntimePaths.isolated { window.setFrameAutosaveName("KhulumaStats") }
    window.appearance = Self.forcedAppearance
    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "Khuluma.Main")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    window.toolbarStyle = .unifiedCompact
    window.toolbar = toolbar
    window.onSettings = { [weak self] in self?.openSettings() }
    window.onBack = { [weak self] in self?.backToStats() }
    window.onRefresh = { [weak self] in self?.refreshStats() }
    window.onDismissUsageInfo = { [weak self] in
      guard let self, self.detailsPopover.isShown else { return false }
      self.detailsPopover.performClose(nil)
      return true
    }
    navigation.onChange = { [weak self] in self?.updateChrome() }
    updateChrome()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
    model.windowOpened()
  }

  @objc private func openSettings() { navigation.selection = .settings }
  @objc private func backToStats() { navigation.selection = .stats }
  @objc private func refreshStats() { model.reload() }

  @objc private func showUsageInfo(_ sender: NSButton) {
    if detailsPopover.isShown {
      detailsPopover.performClose(sender)
      return
    }
    let content = NSHostingController(rootView: StatsDetailsView(model: model))
    content.sizingOptions = [.preferredContentSize]
    detailsPopover.contentViewController = content
    detailsPopover.behavior = .transient
    detailsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
  }

  private func updateChrome() {
    guard let window = window as? StatsWindow, let toolbar = window.toolbar else { return }
    detailsPopover.performClose(nil)
    let settings = navigation.selection == .settings
    window.showingSettings = settings
    window.title = settings ? "Settings" : "Khuluma"
    // The preview must stay visibly distinct from the daily app.
    if AppRuntimePaths.isolated {
      window.title = settings ? "Settings · Preview" : "Khuluma Preview · Sample Data"
    }
    let desired: [NSToolbarItem.Identifier] = settings
      ? [Self.backItem, .flexibleSpace] : [.flexibleSpace, Self.infoItem, Self.refreshItem, Self.settingsItem]
    guard toolbar.items.map(\.itemIdentifier) != desired else { return }
    for index in toolbar.items.indices.reversed() { toolbar.removeItem(at: index) }
    for (index, identifier) in desired.enumerated() { toolbar.insertItem(withItemIdentifier: identifier, at: index) }
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [Self.backItem, .flexibleSpace, Self.infoItem, Self.refreshItem, Self.settingsItem]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.infoItem, Self.refreshItem, Self.settingsItem]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    let label: String
    let symbol: String
    let action: Selector
    let help: String
    switch identifier {
    case Self.settingsItem:
      (label, symbol, action, help) = ("Settings", "gearshape", #selector(openSettings), "Settings (⌘,)")
    case Self.refreshItem:
      (label, symbol, action, help) = ("Refresh", "arrow.clockwise", #selector(refreshStats), "Refresh (⌘R)")
    case Self.infoItem:
      (label, symbol, action, help) = ("Usage information", "info.circle", #selector(showUsageInfo(_:)), "Usage information")
    case Self.backItem:
      (label, symbol, action, help) = ("Back", "chevron.left", #selector(backToStats), "Back to Stats (⌘[)")
    default:
      return nil
    }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.toolTip = help
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.target = self
    item.isNavigational = identifier == Self.backItem
    item.action = action
    if identifier != Self.backItem, let image = item.image {
      let button = NSButton(image: image, target: self, action: action)
      button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
      button.imageScaling = .scaleNone
      button.bezelStyle = .texturedRounded
      button.controlSize = .small
      button.showsBorderOnlyWhileMouseInside = true
      button.toolTip = item.toolTip
      button.setAccessibilityLabel(label)
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 28),
        button.heightAnchor.constraint(equalToConstant: 24),
      ])
      item.view = button
    }
    return item
  }

  func windowDidBecomeKey(_ notification: Notification) { model.windowBecameKey() }
  func windowWillClose(_ notification: Notification) {
    detailsPopover.performClose(nil)
    model.windowClosed()
  }
}

@MainActor
final class AppNavigation: ObservableObject {
  enum Page { case stats, settings }
  @Published var selection: Page = .stats { didSet { onChange() } }
  var onChange: () -> Void = {}
}

struct AppView: View {
  @ObservedObject var stats: StatsModel
  @ObservedObject var settings: SettingsModel
  @ObservedObject var navigation: AppNavigation

  var body: some View {
    Group {
      if navigation.selection == .stats {
        ScrollView { StatsView(model: stats).frame(maxWidth: .infinity) }
      } else {
        SettingsView(model: settings)
      }
    }
    .frame(minWidth: 560, minHeight: 420)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private final class StatsWindow: NSWindow {
  var onSettings: () -> Void = {}
  var onBack: () -> Void = {}
  var onRefresh: () -> Void = {}
  var onDismissUsageInfo: () -> Bool = { false }
  var showingSettings = false

  override func cancelOperation(_ sender: Any?) {
    if onDismissUsageInfo() { return }
    if showingSettings { onBack() } else { performClose(sender) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command {
      switch event.charactersIgnoringModifiers {
      case "w": performClose(nil); return true
      case ",": onSettings(); return true
      case "[" where showingSettings: onBack(); return true
      case "r" where !showingSettings: onRefresh(); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }
}
