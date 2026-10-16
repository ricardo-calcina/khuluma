import AppKit
import Foundation
import KhulumaCore

/// The menu-bar item and its menu. It only shows what the controller tells
/// it and passes clicks back through the `on…` closures.
final class StatusMenu: NSObject, NSMenuDelegate {
  var onCancelRecording: () -> Void = {}
  var onRetryTimedOut: () -> Void = {}
  var onPasteRetried: () -> Void = {}
  var onDiscardTimedOut: () -> Void = {}
  var onDiscardUnsaved: () -> Void = {}
  var onShowRecovered: () -> Void = {}
  var onShowStats: () -> Void = {}
  var onReloadSettings: () -> Void = {}
  var onToggleLogin: () -> Void = {}
  var onWillOpen: () -> Void = {}

  private var statusItem: NSStatusItem?
  private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
  private let hotkeyLine = NSMenuItem(title: "Hotkey: –", action: nil, keyEquivalent: "")
  private let configLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let recoveredLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let daemonLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let retryItem = NSMenuItem(title: "", action: #selector(retryTimedOut), keyEquivalent: "")
  private let pasteRetriedItem = NSMenuItem(title: "", action: #selector(pasteRetried), keyEquivalent: "")
  private let discardTimedOutItem = NSMenuItem(title: "Discard timed-out recording", action: #selector(discardTimedOut), keyEquivalent: "")
  private let discardUnsavedItem = NSMenuItem(title: "", action: #selector(discardUnsaved), keyEquivalent: "")
  private let cancelItem = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
  private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")

  func install() {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    self.statusItem = statusItem
    let menu = NSMenu()
    statusLine.isEnabled = false
    hotkeyLine.isEnabled = false
    configLine.isEnabled = false
    configLine.isHidden = true
    recoveredLine.isEnabled = false
    recoveredLine.isHidden = true
    menu.addItem(statusLine)
    menu.addItem(hotkeyLine)
    menu.addItem(configLine)
    menu.addItem(recoveredLine)
    daemonLine.isEnabled = false
    daemonLine.isHidden = true
    menu.addItem(daemonLine)
    for item in [retryItem, pasteRetriedItem, discardTimedOutItem, discardUnsavedItem] {
      item.target = self
      item.isHidden = true
      menu.addItem(item)
    }
    menu.addItem(.separator())
    cancelItem.target = self
    menu.addItem(cancelItem)
    let stats = NSMenuItem(title: "Stats…", action: #selector(showStats), keyEquivalent: "s")
    stats.target = self
    menu.addItem(stats)
    let reload = NSMenuItem(title: "Reload Settings", action: #selector(reloadSettings), keyEquivalent: "r")
    reload.target = self
    menu.addItem(reload)
    let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "l")
    log.target = self
    menu.addItem(log)
    loginItem.target = self
    menu.addItem(loginItem)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Lowkey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    menu.delegate = self
    statusItem.menu = menu
    show(ActivityStatus(), recording: false)
  }

  func menuWillOpen(_ menu: NSMenu) {
    onWillOpen()
  }

  // MARK: - What the menu shows

  /// The icon and first line; Cancel Recording only while recording.
  func show(_ status: ActivityStatus, recording: Bool) {
    statusLine.title = status.title
    cancelItem.isHidden = !recording
    let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "Lowkey")
    image?.isTemplate = true
    statusItem?.button?.image = image
  }

  func showHotkey(_ title: String) {
    hotkeyLine.title = title
  }

  /// A warning while config.toml doesn't parse; nil hides it.
  func showConfigWarning(_ title: String?) {
    configLine.title = title ?? ""
    configLine.isHidden = title == nil
  }

  /// Saved dictations: `action` makes the line open them in Finder.
  func showRecovered(_ title: String, action: Bool) {
    recoveredLine.title = title
    recoveredLine.isEnabled = action
    recoveredLine.action = action ? #selector(showRecoveredFolder) : nil
    recoveredLine.target = action ? self : nil
    recoveredLine.isHidden = false
  }

  /// The Parakeet daemon's state; nil hides the line.
  func showDaemon(_ title: String?) {
    if let title { daemonLine.title = title }
    daemonLine.isHidden = title == nil
  }

  /// Retry / Paste / Discard for timed-out takes; a nil title hides the item.
  func showTimedOut(retry: String?, paste: String?, discard: String?) {
    for (item, title) in [(retryItem, retry), (pasteRetriedItem, paste), (discardTimedOutItem, discard)] {
      if let title { item.title = title }
      item.isHidden = title == nil
    }
  }

  /// "Discard … and quit" for takes Quit couldn't save; nil hides it.
  func showDiscardUnsaved(_ title: String?) {
    if let title { discardUnsavedItem.title = title }
    discardUnsavedItem.isHidden = title == nil
  }

  func showLogin(_ status: LoginItem.Status) {
    loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
    loginItem.title = status == .requiresApproval ? "Start at Login (approve in System Settings)" : "Start at Login"
  }

  // MARK: - Clicks

  @objc private func cancelRecording() { onCancelRecording() }
  @objc private func retryTimedOut() { onRetryTimedOut() }
  @objc private func pasteRetried() { onPasteRetried() }
  @objc private func discardTimedOut() { onDiscardTimedOut() }
  @objc private func discardUnsaved() { onDiscardUnsaved() }
  @objc private func showRecoveredFolder() { onShowRecovered() }
  @objc private func showStats() { onShowStats() }
  @objc private func reloadSettings() { onReloadSettings() }
  @objc private func toggleLogin() { onToggleLogin() }
  @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
}
