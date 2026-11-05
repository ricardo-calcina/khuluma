import AppKit
import KhulumaCore

/// The menu's microphone list, inline like the system Sound menu: a
/// "Microphone" section header, then one native row per option with a
/// checkmark on the choice. Changes apply from the next take.
final class MicrophoneMenu: NSObject {
  /// The header and rows, in order; `refresh` replaces them in place.
  private(set) var items: [NSMenuItem] = []
  private weak var menu: NSMenu?
  private let settings: SettingsModel
  /// The menu's content width: a right-aligned detail ends inside it.
  private let width: CGFloat
  private lazy var detailTab: CGFloat = Self.detailTabStop(width: width)
  private let font = NSFont.menuFont(ofSize: 0)

  init(settings: SettingsModel, width: CGFloat) {
    self.settings = settings
    self.width = width
    super.init()
  }

  /// Adds the list to the end of `menu`.
  func install(in menu: NSMenu) {
    self.menu = menu
    items = makeItems()
    items.forEach(menu.addItem)
  }

  /// Rebuilds the list in place; safe while the menu is open.
  func refresh() {
    guard let menu, let first = items.first else { return }
    let index = menu.index(of: first)
    guard index >= 0 else { return }
    let fresh = makeItems()
    guard !Self.same(fresh, items) else { return }
    items.forEach(menu.removeItem)
    for (offset, item) in fresh.enumerated() { menu.insertItem(item, at: index + offset) }
    items = fresh
  }

  private func makeItems() -> [NSMenuItem] {
    let choice = settings.microphoneChoice
    var rows = [NSMenuItem.sectionHeader(title: "Microphone")]
    for option in choice.options {
      let row = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
      row.target = self
      row.representedObject = option.uid
      row.state = option.checked ? .on : .off
      row.isEnabled = option.connected
      // A chosen device that couldn't be used: takes use the system default.
      let unusable = option.uid != nil && option.uid == choice.unusableUID
      if let detail = unusable ? "Not available" : option.detail {
        row.attributedTitle = title(option.title, detail: detail, enabled: option.connected)
      }
      if option.checked || unusable { row.toolTip = choice.note }
      rows.append(row)
    }
    return rows
  }

  /// Rows are compared by what they show, so an unchanged list isn't rebuilt mid-tracking.
  private static func same(_ a: [NSMenuItem], _ b: [NSMenuItem]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy {
      $0.title == $1.title && $0.attributedTitle == $1.attributedTitle && $0.state == $1.state
        && $0.isEnabled == $1.isEnabled && ($0.representedObject as? String) == ($1.representedObject as? String)
        && $0.toolTip == $1.toolTip
    }
  }

  @objc private func choose(_ sender: NSMenuItem) {
    settings.selectMicrophone(uid: sender.representedObject as? String)
  }

  /// The option and its secondary detail, right-aligned with a tab stop so
  /// the menu keeps its width.
  private func title(_ label: String, detail: String, enabled: Bool) -> NSAttributedString {
    let room = detailTab - measure(label) - 24
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: detailTab)]
    paragraph.lineBreakMode = .byClipping
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
    if !enabled { attributes[.foregroundColor] = NSColor.disabledControlTextColor }
    let title = NSMutableAttributedString(string: label, attributes: attributes)
    attributes[.foregroundColor] = enabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor
    title.append(NSAttributedString(string: "\t" + truncated(detail, to: room), attributes: attributes))
    return title
  }

  private func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

  private func truncated(_ text: String, to room: CGFloat) -> String {
    guard measure(text) > room else { return text }
    var characters = Array(text)
    while !characters.isEmpty, measure(String(characters) + "…") > room { characters.removeLast() }
    return String(characters).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Where a detail must end for the row to fit `width`: the menu's own
  /// insets (state column, padding) measured on a scratch menu, so the row
  /// tracks the system's metrics rather than a guessed constant.
  private static func detailTabStop(width: CGFloat) -> CGFloat {
    let probeTab: CGFloat = 1_000
    let probe = NSMenu()
    probe.showsStateColumn = true
    let row = NSMenuItem()
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: probeTab)]
    row.attributedTitle = NSAttributedString(string: "M\tM", attributes: [
      .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
    row.state = .on
    probe.addItem(row)
    let overhead = probe.size.width - probeTab
    guard overhead.isFinite, overhead > 0, overhead < width / 2 else { return width - 60 }
    return width - overhead
  }
}
