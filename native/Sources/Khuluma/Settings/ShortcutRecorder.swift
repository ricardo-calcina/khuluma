import AppKit
import KhulumaCore
import SwiftUI

/// A keyboard-accessible shortcut recorder. Capture belongs to this control's
/// window and ends when focus, visibility or enabled state changes.
struct ShortcutRecorder: NSViewRepresentable {
  let value: String
  let isEnabled: Bool
  let onCapture: (String) -> Void
  let onRecordingChange: (Bool) -> Void

  init(
    value: String,
    isEnabled: Bool = true,
    onCapture: @escaping (String) -> Void,
    onRecordingChange: @escaping (Bool) -> Void = { _ in }
  ) {
    self.value = value
    self.isEnabled = isEnabled
    self.onCapture = onCapture
    self.onRecordingChange = onRecordingChange
  }

  func makeNSView(context: Context) -> NSView {
    let control = ShortcutRecorderControl()
    update(control)
    return control
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let control = nsView as? ShortcutRecorderControl else { return }
    update(control)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    (nsView as? ShortcutRecorderControl)?.cancelRecording()
  }

  private func update(_ control: ShortcutRecorderControl) {
    control.update(value: value, isEnabled: isEnabled, onCapture: onCapture, onRecordingChange: onRecordingChange)
  }
}

private final class ShortcutRecorderControl: NSStackView {
  private let button = ShortcutRecorderButton()
  private let hint = NSTextField(wrappingLabelWithString: "Modifiers or an F-key. Esc cancels.")
  private var value = ""
  private var isRecording = false
  private var eventMonitor: Any?
  private var windowObserver: NSObjectProtocol?
  private var onCapture: (String) -> Void = { _ in }
  private var onRecordingChange: (Bool) -> Void = { _ in }

  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 5

    button.bezelStyle = .rounded
    button.controlSize = .regular
    button.target = self
    button.action = #selector(beginRecording)
    button.focusRingType = .exterior
    button.setAccessibilityLabel("Dictation shortcut")
    button.onFocusLost = { [weak self] in self?.cancelRecording() }
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    addArrangedSubview(button)

    hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    hint.textColor = .secondaryLabelColor
    hint.maximumNumberOfLines = 2
    hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hint.heightAnchor.constraint(equalToConstant: 28).isActive = true
    hint.setAccessibilityLabel("Shortcut help")
    addArrangedSubview(hint)
    hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 61) }

  deinit {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
  }

  func update(
    value: String,
    isEnabled: Bool,
    onCapture: @escaping (String) -> Void,
    onRecordingChange: @escaping (Bool) -> Void
  ) {
    self.value = value
    self.onCapture = onCapture
    self.onRecordingChange = onRecordingChange
    button.isEnabled = isEnabled
    if !isEnabled { cancelRecording() }
    updateTitle()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { cancelRecording() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidHide() {
    cancelRecording()
    super.viewDidHide()
  }

  @objc private func beginRecording() {
    guard button.isEnabled, let window else { return }
    if isRecording {
      cancelRecording()
      return
    }
    guard window.makeFirstResponder(button) else { return }
    isRecording = true
    setHint("Press your shortcut. Esc cancels.")
    updateTitle()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isRecording, event.window === self.window else { return event }
      return self.capture(event)
    }
    windowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { [weak self] _ in self?.cancelRecording() }
    onRecordingChange(true)
  }

  private func capture(_ event: NSEvent) -> NSEvent? {
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    if event.keyCode == 53 && flags.isEmpty {
      cancelRecording()
      return nil
    }
    // Tab and Shift+Tab keep their standard focus-navigation behavior.
    if event.keyCode == 48 && flags.subtracting(.shift).isEmpty {
      let window = self.window
      cancelRecording()
      if flags.contains(.shift) { window?.selectPreviousKeyView(button) }
      else { window?.selectNextKeyView(button) }
      return nil
    }
    guard !event.isARepeat else { return nil }
    var modifiers: UInt32 = 0
    if flags.contains(.control) { modifiers |= HotkeySpec.controlMask }
    if flags.contains(.option) { modifiers |= HotkeySpec.optionMask }
    if flags.contains(.shift) { modifiers |= HotkeySpec.shiftMask }
    if flags.contains(.command) { modifiers |= HotkeySpec.commandMask }
    do {
      let captured = try HotkeySpec.configText(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
      finishRecording(captured: captured)
    } catch {
      setHint(String(describing: error), isError: true)
    }
    return nil
  }

  func cancelRecording() { finishRecording(captured: nil) }

  private func finishRecording(captured: String?) {
    guard isRecording else { return }
    isRecording = false
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    if let windowObserver {
      NotificationCenter.default.removeObserver(windowObserver)
      self.windowObserver = nil
    }
    setHint("Modifiers or an F-key. Esc cancels.")
    updateTitle()
    // Applying a shortcut comes first, so a caller restoring its global
    // monitor on false can use the newly selected binding.
    if let captured { onCapture(captured) }
    onRecordingChange(false)
  }

  private func updateTitle() {
    let display = (try? HotkeySpec.parse(value).display) ?? value
    button.title = isRecording ? "Press a shortcut…" : "\(display)  ·  Record shortcut"
    button.setAccessibilityValue(isRecording ? "Recording shortcut" : display)
    button.setAccessibilityHelp(isRecording ? "Press your shortcut, or Escape to cancel." : "Activate to record a new shortcut.")
  }

  private func setHint(_ text: String, isError: Bool = false) {
    hint.stringValue = text
    hint.toolTip = text
    hint.textColor = isError ? .systemRed : .secondaryLabelColor
    hint.setAccessibilityValue(text)
  }
}

private final class ShortcutRecorderButton: NSButton {
  var onFocusLost: () -> Void = {}

  override var acceptsFirstResponder: Bool { isEnabled }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusLost() }
    return resigned
  }
}
