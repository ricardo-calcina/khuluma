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
  private weak var tabs: NSToolbarItemGroup?
  private static let tabsItem = NSToolbarItem.Identifier("Khuluma.Tabs")
  private static let refreshItem = NSToolbarItem.Identifier("Khuluma.Refresh")
  private static let infoItem = NSToolbarItem.Identifier("Khuluma.UsageInfo")

  init(model: StatsModel, settings: SettingsModel) {
    self.model = model
    let vocabulary = VocabularyModel(settings: settings)
    self.vocabulary = vocabulary
    let window = StatsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 634),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Khuluma"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: AppView(
      stats: model, settings: settings, navigation: navigation, vocabulary: vocabulary))
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
    toolbar.centeredItemIdentifiers = [Self.tabsItem]
    window.toolbarStyle = .unifiedCompact
    window.toolbar = toolbar
    window.onSelect = { [weak self] page in self?.navigation.selection = page }
    window.onRefresh = { [weak self] in self?.refreshStats() }
    window.onDismissUsageInfo = { [weak self] in
      guard let self, self.detailsPopover.isShown else { return false }
      self.detailsPopover.performClose(nil)
      return true
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
    NSApp.activate()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    model.windowOpened()
  }

  @objc private func selectTab(_ sender: Any?) {
    guard let index = tabs?.selectedIndex, AppNavigation.Page.allCases.indices.contains(index) else { return }
    navigation.selection = AppNavigation.Page.allCases[index]
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
      for identifier in statsItems { toolbar.insertItem(withItemIdentifier: identifier, at: toolbar.items.count) }
    } else if page != .stats, !showing.isEmpty {
      for index in toolbar.items.indices.reversed() where statsItems.contains(toolbar.items[index].itemIdentifier) {
        toolbar.removeItem(at: index)
      }
    }
    tabs?.selectedIndex = AppNavigation.Page.allCases.firstIndex(of: page) ?? 0
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.tabsItem, Self.infoItem, Self.refreshItem]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.tabsItem, .flexibleSpace, Self.infoItem, Self.refreshItem]
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    if identifier == Self.tabsItem {
      let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: AppNavigation.Page.allCases.map(\.title),
                                     selectionMode: .selectOne, labels: nil, target: self,
                                     action: #selector(selectTab(_:)))
      group.label = "View"
      group.toolTip = "Stats (⌘1), Vocabulary (⌘2), Settings (⌘3 or ⌘,)"
      group.selectedIndex = AppNavigation.Page.allCases.firstIndex(of: navigation.selection) ?? 0
      tabs = group
      return group
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
    detailsPopover.performClose(nil)
    model.windowClosed()
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
      }
    }
    .frame(minWidth: 560, minHeight: 420)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private final class StatsWindow: NSWindow {
  var onSelect: (AppNavigation.Page) -> Void = { _ in }
  var onRefresh: () -> Void = {}
  var onDismissUsageInfo: () -> Bool = { false }
  var page = AppNavigation.Page.stats

  /// Escape closes usage information, then returns to Stats, then closes.
  override func cancelOperation(_ sender: Any?) {
    if onDismissUsageInfo() { return }
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
