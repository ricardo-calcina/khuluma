import Foundation

/// The steps that put a transcript into the target app, mirroring the CLI's
/// osascript delivery (bin/khuluma process_inline_recording).
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
  /// Put back what was on the clipboard before the dictation, `afterMs`
  /// after it. Reached only when every key step has succeeded.
  case restoreClipboard(afterMs: Int)
}

/// Which app a take's auto-send choice comes from, per `inline.app_rules`.
public enum AppRules {
  /// The matching rule's answer, or the global default when the app is
  /// unknown or unlisted (bundle ids compare case-insensitively).
  public static func autosend(bundleID: String?, default defaultValue: Bool,
                              rules: [AppSettings.AppRule]) -> (autosend: Bool, matched: Bool) {
    guard let bundleID,
          let rule = rules.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })
    else { return (defaultValue, false) }
    return (rule.autosend, true)
  }
}

/// The restore-the-clipboard decision, kept pure for tests.
public enum ClipboardRestore {
  public enum Plan: Equatable, Sendable {
    case restore
    /// The log reason: "empty" (nothing to put back) or "too_large".
    case skip(String)
  }

  public static func plan(itemSizes: [Int], limitBytes: Int) -> Plan {
    guard !itemSizes.isEmpty else { return .skip("empty") }
    return itemSizes.reduce(0, +) > limitBytes ? .skip("too_large") : .restore
  }

  /// Restore only when the pasteboard still holds what was written.
  public static func shouldRestore(written: Int, current: Int) -> Bool {
    written == current
  }
}

/// Which app a take is delivered to.
public enum DeliveryTarget {
  /// Khuluma never pastes into itself (e.g. with its own window in front):
  /// the text would land nowhere yet count as delivered.
  public static func isSelf(frontmostPID: Int32?, ownPID: Int32) -> Bool {
    frontmostPID == ownPID
  }

  /// The take's original app: the frontmost one, or the last other app that
  /// was active when Khuluma itself is in front at the hotkey.
  public static func original<App>(frontmost: App?, lastExternal: App?, isSelf: (App) -> Bool) -> App? {
    guard let frontmost, isSelf(frontmost) else { return frontmost }
    return lastExternal.flatMap { isSelf($0) ? nil : $0 }
  }

  /// The app recorded in history: the one the text is delivered to.
  /// "restore" and retargeted takes go to the app from recording start;
  /// "current" to whatever is frontmost at stop.
  public static func deliveryApp(pasteTarget: String?, retargeted: Bool, original: String?,
                             frontmostAtStop: String?) -> String? {
    pasteTarget == "restore" || retargeted ? original : frontmostAtStop
  }
}

/// The local calendar date usage is counted under.
public enum LocalDate {
  /// YYYY-MM-DD in the Gregorian calendar, whatever calendar the user has
  /// chosen, in `timeZone`.
  public static func string(for date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
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

  /// How long after pasting the previous clipboard is restored.
  public static let clipboardRestoreDelayMs = 400
  /// A snapshot bigger than this is left alone ("too_large").
  public static let clipboardRestoreLimitBytes = 20_000_000

  public static func steps(text: String, delivery: Delivery, hasOriginalApp: Bool) -> [DeliveryStep] {
    let steps = keySteps(text: text, delivery: delivery, hasOriginalApp: hasOriginalApp)
    if delivery.restoreClipboard {
      return steps + [.restoreClipboard(afterMs: clipboardRestoreDelayMs)]
    }
    return steps
  }

  private static func keySteps(text: String, delivery: Delivery, hasOriginalApp: Bool) -> [DeliveryStep] {
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

  /// The deliberate waits in a plan (activation and send gaps), so the take
  /// log can tell them apart from processing time.
  public static func waitMs(_ steps: [DeliveryStep]) -> Int {
    steps.reduce(0) { total, step in
      if case .wait(let milliseconds) = step { return total + milliseconds }
      return total
    }
  }
}
