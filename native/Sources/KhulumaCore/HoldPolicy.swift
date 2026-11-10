import Foundation

/// Hold-to-talk: what releasing the hold key does to a take, and which
/// shortcuts may be bound to it (Settings › Dictation › Hold to talk).
public enum HoldPolicy {
  public enum Action: Equatable, Sendable {
    /// A tap: the take is thrown away.
    case discard
    /// Held long enough to mean it: finish after a short tail, so the last
    /// word is captured.
    case finish(tailMs: Int)
  }

  /// Under 300 ms is a tap; longer finishes the take with a 200 ms tail.
  public static func onRelease(heldMs: Int) -> Action {
    heldMs < 300 ? .discard : .finish(tailMs: 200)
  }

  /// What `hotkey` decided: a parsed spec (nil = off), or why it refused.
  public enum Choice: Equatable, Sendable {
    case ok(HotkeySpec?)
    case refused(String)
  }

  /// The "Hold to talk" rule: "" turns it off; anything else must pass the
  /// app's hotkey rule and not collide with the dictation shortcut, the
  /// Control–Escape cancel or the paste-without-sending stop shortcut.
  public static func hotkey(_ text: String, toggle: HotkeySpec?, pasteOnly: HotkeySpec?) -> Choice {
    if text.isEmpty { return .ok(nil) }
    guard AppSettings.isValidHotkey(text), let spec = try? HotkeySpec.parse(text) else {
      return .refused("invalid hotkey; use a modifier and key, or F1–F20")
    }
    if spec == toggle {
      return .refused("\(spec.display) is the dictation shortcut; choose another")
    }
    if spec == (try? HotkeySpec.parse("ctrl+escape")) {
      return .refused("\(spec.display) cancels a take; choose another")
    }
    if let pasteOnly, spec == pasteOnly {
      return .refused("\(spec.display) pastes without sending; choose another")
    }
    return .ok(spec)
  }
}
