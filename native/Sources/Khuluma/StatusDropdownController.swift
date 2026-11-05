import AppKit
import SwiftUI

/// Rich views in a native menu, using the same container as Sys Stats, with
/// native items (such as a submenu) between them. AppKit owns placement,
/// material, highlighting and all menu tracking.
final class StatusDropdownController: NSObject, NSMenuDelegate {
  let menu = NSMenu()
  var onOpen: () -> Void = {}
  var onClose: () -> Void = {}
  /// Runs before each open, after the hosted views are fitted.
  var onNeedsUpdate: () -> Void = {}
  private var hosted: [NSMenuItem] = []
  private var fitting = false
  private(set) var isPresented = false

  override init() {
    super.init()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.delegate = self
  }

  /// Appends a hosted SwiftUI view, fitted to its content.
  func addHosted(_ view: NSView) {
    let item = NSMenuItem()
    item.view = view
    view.autoresizingMask = [.width]
    hosted.append(item)
    menu.addItem(item)
    fitToContent()
  }

  /// Appends a native item (separator, submenu, action).
  func addNative(_ item: NSMenuItem) { menu.addItem(item) }

  func fitToContent() {
    guard !fitting else { return }
    fitting = true
    defer { fitting = false }
    for item in hosted { fit(item) }
  }

  private func fit(_ item: NSMenuItem) {
    guard let view = item.view else { return }
    view.layoutSubtreeIfNeeded()
    let natural = view.fittingSize
    guard natural.width.isFinite, natural.height.isFinite,
          natural.width > 0, natural.height > 0 else { return }
    let size = NSSize(width: ceil(natural.width), height: ceil(natural.height))
    guard view.frame.size != size else { return }
    view.setFrameSize(size)
    if isPresented { menu.itemChanged(item) }
  }

  func dismiss() { menu.cancelTracking() }
  func menuNeedsUpdate(_ menu: NSMenu) { fitToContent(); onNeedsUpdate() }
  func menuWillOpen(_ menu: NSMenu) { isPresented = true; onOpen() }
  func menuDidClose(_ menu: NSMenu) { isPresented = false; onClose() }
}

/// Native menu rows refit from their view frame, including during tracking.
final class StatusMenuHostingView<Content: View>: NSHostingView<Content> {
  var onSizeChange: () -> Void = {}

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    RunLoop.main.perform(inModes: [.common], block: onSizeChange)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    // SwiftUI assigns initial button focus one pass after joining the menu.
    RunLoop.main.perform(inModes: [.common]) {
      RunLoop.main.perform(inModes: [.common]) { window.makeFirstResponder(nil) }
    }
  }
}
