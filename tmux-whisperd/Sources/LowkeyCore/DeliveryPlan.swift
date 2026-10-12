/// The steps that put a transcript into the target app, mirroring the CLI's
/// osascript delivery (bin/tmux-whisper process_inline_recording).
public enum DeliveryStep: Equatable, Sendable {
  case setClipboard(String)
  /// Re-activate the app that was frontmost when recording started.
  case activateOriginalApp
  case wait(milliseconds: Int)
  /// A character shortcut (Cmd+V, Ctrl+J). Resolved to a key code through the
  /// active keyboard layout at delivery time, like AppleScript's `keystroke`,
  /// so it works on Dvorak, AZERTY, etc.
  case shortcut(character: Character, command: Bool, control: Bool)
  /// A layout-independent key (Return), as an ANSI virtual key code.
  case key(code: UInt16, command: Bool, control: Bool)
}

public enum DeliveryPlan {
  public static let keyReturn: UInt16 = 36
  /// The shortest wait between Cmd+V and the send key. The CLI posts them
  /// from two `osascript` runs, so its send key lands `send_delay_ms` plus
  /// ~80 ms of process launch after the paste. Posted back to back, Electron
  /// apps (the Claude desktop app) sometimes take the send key before the
  /// paste (Cmd+V goes through their Edit menu), so the text is pasted but
  /// not sent.
  public static let minimumSendGapMs = 150

  public static func steps(text: String, delivery: Delivery, hasOriginalApp: Bool) -> [DeliveryStep] {
    var steps: [DeliveryStep] = [.setClipboard(text)]
    if delivery.pasteTarget == "restore" && hasOriginalApp {
      steps.append(.activateOriginalApp)
      if delivery.activateDelayMs > 0 {
        steps.append(.wait(milliseconds: delivery.activateDelayMs))
      }
    }
    steps.append(.shortcut(character: "v", command: true, control: false))
    guard delivery.autosend else { return steps }

    // Give the target app a moment to insert the paste before sending.
    steps.append(.wait(milliseconds: max(delivery.sendDelayMs, minimumSendGapMs)))
    switch delivery.sendMode {
    case "ctrl_j":
      steps.append(.shortcut(character: "j", command: false, control: true))
    case "cmd_enter":
      steps.append(.key(code: keyReturn, command: true, control: false))
    default:
      steps.append(.key(code: keyReturn, command: false, control: false))
    }
    return steps
  }
}
