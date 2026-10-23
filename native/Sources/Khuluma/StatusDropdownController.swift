import AppKit
import SwiftUI

/// A rich view in a native menu, using the same container as Sys Stats.
/// AppKit owns placement, material, highlighting and all menu tracking.
final class StatusDropdownController: NSObject, NSMenuDelegate {
  let menu = NSMenu()
  var onOpen: () -> Void = {}
  var onClose: () -> Void = {}
  private let item = NSMenuItem()
  private var fitting = false
  private(set) var isPresented = false

  override init() {
    super.init()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.delegate = self
    menu.addItem(item)
  }

  func setContent(_ view: NSView) {
    item.view = view
    view.autoresizingMask = [.width]
    fitToContent()
  }

  func fitToContent() {
    guard !fitting, let view = item.view else { return }
    fitting = true
    defer { fitting = false }
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
  func menuNeedsUpdate(_ menu: NSMenu) { fitToContent() }
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
