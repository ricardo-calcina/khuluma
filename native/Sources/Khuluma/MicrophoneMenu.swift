import AppKit
import KhulumaCore

/// The menu's Microphone row: a native item showing the input the next take
/// uses, with a native submenu to choose it. Changes apply from the next take.
final class MicrophoneMenu: NSObject {
  let item = NSMenuItem()
  private let submenu = NSMenu(title: "Microphone")
  private let settings: SettingsModel
  /// The menu's content width: the right-aligned value ends inside it.
  private let width: CGFloat
  private lazy var valueTab: CGFloat = Self.valueTabStop(width: width)
  private let font = NSFont.menuFont(ofSize: 0)

  init(settings: SettingsModel, width: CGFloat) {
    self.settings = settings
    self.width = width
    super.init()
    submenu.autoenablesItems = false
    item.submenu = submenu
    item.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
    refresh()
  }

  /// Rebuilds the row and the list; safe while the menu is open.
  func refresh() {
    let choice = settings.microphoneChoice
    let title = rowTitle(choice.summary)
    if item.attributedTitle != title { item.attributedTitle = title }
    item.toolTip = choice.note
    submenu.removeAllItems()
    for (index, option) in choice.options.enumerated() {
      let entry = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
      entry.target = self
      entry.representedObject = option.uid
      entry.state = option.checked ? .on : .off
      entry.isEnabled = option.connected
      if let detail = option.detail {
        if #available(macOS 14.4, *) { entry.subtitle = detail } else { entry.title += " (\(detail))" }
      }
      submenu.addItem(entry)
      if index == 0, choice.options.count > 1 { submenu.addItem(.separator()) }
    }
    submenu.addItem(.separator())
    let sound = NSMenuItem(title: "Sound Settings…", action: #selector(openSoundSettings), keyEquivalent: "")
    sound.target = self
    submenu.addItem(sound)
  }

  @objc private func choose(_ sender: NSMenuItem) {
    settings.selectMicrophone(uid: sender.representedObject as? String)
  }

  @objc private func openSoundSettings() { AudioInputDevices.openSoundSettings() }

  /// "Microphone" and the value, right-aligned with a tab stop so the row
  /// reads like a native setting and the menu keeps its width.
  private func rowTitle(_ value: String) -> NSAttributedString {
    let label = "Microphone"
    let room = valueTab - measure(label) - 24
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: valueTab)]
    paragraph.lineBreakMode = .byClipping
    let title = NSMutableAttributedString(string: label, attributes: [.font: font, .paragraphStyle: paragraph])
    title.append(NSAttributedString(string: "\t" + truncated(value, to: room), attributes: [
      .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor]))
    return title
  }

  private func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

  private func truncated(_ text: String, to room: CGFloat) -> String {
    guard measure(text) > room else { return text }
    var characters = Array(text)
    while !characters.isEmpty, measure(String(characters) + "…") > room { characters.removeLast() }
    return String(characters).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Where the value must end for the row to fit `width`: the menu's own
  /// insets (image, submenu arrow, padding) measured on a scratch menu, so
  /// the row tracks the system's metrics rather than a guessed constant.
  private static func valueTabStop(width: CGFloat) -> CGFloat {
    let probeTab: CGFloat = 1_000
    let probe = NSMenu()
    probe.showsStateColumn = false
    let row = NSMenuItem()
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: probeTab)]
    row.attributedTitle = NSAttributedString(string: "M\tM", attributes: [
      .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
    row.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
    row.submenu = NSMenu()
    probe.addItem(row)
    let overhead = probe.size.width - probeTab
    guard overhead.isFinite, overhead > 0, overhead < width / 2 else { return width - 80 }
    return width - overhead
  }
}
