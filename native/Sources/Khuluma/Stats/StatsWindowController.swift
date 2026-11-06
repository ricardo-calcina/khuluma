import AppKit
import SwiftUI
import KhulumaCore

/// Stats, Vocabulary and Settings are tabs in a centred toolbar segmented
/// control, so the whole window stays for content. Stats is home.
@MainActor
final class StatsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  private let model: StatsModel
  private let navigation = AppNavigation()
  private let vocabulary: VocabularyModel
  private let detailsPopover = NSPopover()
  private static let tabsItem = NSToolbarItem.Identifier("Khuluma.Tabs")
  private static let refreshItem = NSToolbarItem.Identifier("Khuluma.Refresh")
  private static let infoItem = NSToolbarItem.Identifier("Khuluma.UsageInfo")
  private static let previewItem = NSToolbarItem.Identifier("Khuluma.Preview")

  private let settingsModel: SettingsModel

  init(model: StatsModel, settings: SettingsModel) {
    self.model = model
    self.settingsModel = settings
    let vocabulary = VocabularyModel(settings: settings)
    self.vocabulary = vocabulary
    let window = StatsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 712),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Khuluma"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: AppView(
      stats: model, settings: settings, navigation: navigation, vocabulary: vocabulary))
    window.setContentSize(NSSize(width: 560, height: 712))
    window.contentMinSize = NSSize(width: 560, height: 420)
    window.center()
    if !AppRuntimePaths.isolated { window.setFrameAutosaveName("KhulumaStats") }
    window.appearance = Self.forcedAppearance
    window.backgroundColor = Surface.canvasColor
    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "Khuluma.Main")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    toolbar.centeredItemIdentifiers = [Self.tabsItem]
    // A visible title takes the toolbar's leading space, and the centred
    // item is centred in what is left, so it sat right of the midpoint.
    window.titleVisibility = .hidden
    window.toolbarStyle = .unifiedCompact
    window.toolbar = toolbar
    window.onSelect = { [weak self] page in self?.navigation.selection = page }
    window.onRefresh = { [weak self] in self?.refreshStats() }
    window.onEscape = { [weak self] in
      guard let self else { return false }
      if self.detailsPopover.isShown { self.detailsPopover.performClose(nil); return true }
      // An open vocabulary row takes Escape; it never switches the tab.
      return self.navigation.selection == .vocabulary && self.vocabulary.escape()
    }
    settings.onManageVocabulary = { [weak self] in self?.navigation.selection = .vocabulary }
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
    // A normal app while the window is open, so it's in Cmd-Tab and the Dock.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    model.windowOpened()
  }

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
    let page = navigation.selection
    window.page = page
    // The preview must stay visibly distinct from the daily app.
    window.title = AppRuntimePaths.isolated ? "Khuluma Preview · Sample Data" : "Khuluma"
    // Refresh and usage information belong to Stats. Only they come and go,
    // so the tab control itself is never rebuilt.
    let statsItems = [Self.infoItem, Self.refreshItem]
    let showing = toolbar.items.map(\.itemIdentifier).filter(statsItems.contains)
    if page == .stats, showing.isEmpty {
      // Before the preview label, which stays last.
      let end = toolbar.items.firstIndex { $0.itemIdentifier == Self.previewItem } ?? toolbar.items.count
      for (offset, identifier) in statsItems.enumerated() { toolbar.insertItem(withItemIdentifier: identifier, at: end + offset) }
    } else if page != .stats, !showing.isEmpty {
      for index in toolbar.items.indices.reversed() where statsItems.contains(toolbar.items[index].itemIdentifier) {
        toolbar.removeItem(at: index)
      }
    }
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.tabsItem, Self.infoItem, Self.refreshItem, Self.previewItem]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // The title is hidden, so an isolated preview says so in the toolbar.
    [.flexibleSpace, Self.tabsItem, .flexibleSpace, Self.infoItem, Self.refreshItem]
      + (AppRuntimePaths.isolated ? [Self.previewItem] : [])
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    if identifier == Self.tabsItem {
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "View"
      item.toolTip = "Stats (⌘1), Vocabulary (⌘2), Settings (⌘3 or ⌘,)"
      // A fixed size from the SwiftUI layout, so the toolbar can centre it.
      let host = NSHostingView(rootView: ToolbarTabs(navigation: navigation))
      let size = host.fittingSize
      host.sizingOptions = []
      host.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        host.widthAnchor.constraint(equalToConstant: size.width),
        host.heightAnchor.constraint(equalToConstant: size.height),
      ])
      item.view = host
      return item
    }
    if identifier == Self.previewItem {
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Preview"
      // Short, so the tabs still fit centred beside Stats' two buttons.
      let text = NSTextField(labelWithString: "Preview")
      text.toolTip = "Khuluma Preview · Sample Data"
      text.font = .systemFont(ofSize: 11)
      text.textColor = .secondaryLabelColor
      item.view = text
      return item
    }
    let label: String
    let symbol: String
    let action: Selector
    let help: String
    switch identifier {
    case Self.refreshItem:
      (label, symbol, action, help) = ("Refresh", "arrow.clockwise", #selector(refreshStats), "Refresh (⌘R)")
    case Self.infoItem:
      (label, symbol, action, help) = ("Usage information", "info.circle", #selector(showUsageInfo(_:)), "Usage information")
    default:
      return nil
    }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = label
    item.toolTip = help
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.target = self
    item.action = action
    if let image = item.image {
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
    settingsModel.keyDraft = ""
    detailsPopover.performClose(nil)
    model.windowClosed()
    // Back to menu bar only once the window is gone. `.common` so it also runs
    // while the status menu is tracking.
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard self?.window?.isVisible != true else { return }
        NSApp.setActivationPolicy(.accessory)
      }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }
}

@MainActor
final class AppNavigation: ObservableObject {
  enum Page: CaseIterable {
    case stats, vocabulary, settings
    var title: String {
      switch self {
      case .stats: return "Stats"
      case .vocabulary: return "Vocabulary"
      case .settings: return "Settings"
      }
    }
  }
  @Published var selection: Page = .stats { didSet { onChange() } }
  var onChange: () -> Void = {}
}

/// Stats | Vocabulary | Settings, in the window's toolbar.
struct ToolbarTabs: View {
  @ObservedObject var navigation: AppNavigation

  var body: some View {
    KhulumaSegments(label: "View", options: AppNavigation.Page.allCases.map { ($0, $0.title) },
                    selection: $navigation.selection, size: .regular)
  }
}

struct AppView: View {
  @ObservedObject var stats: StatsModel
  @ObservedObject var settings: SettingsModel
  @ObservedObject var navigation: AppNavigation
  let vocabulary: VocabularyModel

  var body: some View {
    Group {
      switch navigation.selection {
      case .stats:
        GeometryReader { viewport in
          ScrollView {
            StatsView(model: stats, minimumHeight: viewport.size.height)
              .frame(maxWidth: .infinity)
          }
        }
      case .vocabulary:
        VocabularyView(model: vocabulary, settings: settings)
      case .settings:
        SettingsView(model: settings)
          .onDisappear { settings.keyDraft = "" }
      }
    }
    .frame(minWidth: 560, minHeight: 420)
    .background(Surface.canvas)
  }
}

private final class StatsWindow: NSWindow {
  var onSelect: (AppNavigation.Page) -> Void = { _ in }
  var onRefresh: () -> Void = {}
  /// Usage information or an open vocabulary row handles Escape first.
  var onEscape: () -> Bool = { false }
  var page = AppNavigation.Page.stats

  /// Escape closes usage information, then returns to Stats, then closes.
  override func cancelOperation(_ sender: Any?) {
    if onEscape() { return }
    if page != .stats { onSelect(.stats) } else { performClose(sender) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command {
      switch event.charactersIgnoringModifiers {
      case "w": performClose(nil); return true
      case "1": onSelect(.stats); return true
      case "2": onSelect(.vocabulary); return true
      case "3", ",": onSelect(.settings); return true
      case "r" where page == .stats: onRefresh(); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }
}
