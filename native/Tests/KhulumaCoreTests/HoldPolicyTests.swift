import Testing
@testable import KhulumaCore

/// Hold-to-talk: the release policy and which shortcuts may be bound.
struct HoldPolicyTests {
  @Test func aTapDiscardsTheTake() {
    #expect(HoldPolicy.onRelease(heldMs: 0) == .discard)
    #expect(HoldPolicy.onRelease(heldMs: 299) == .discard)
  }

  @Test func aHoldFinishesWithAShortTail() {
    #expect(HoldPolicy.onRelease(heldMs: 300) == .finish(tailMs: 200))
    #expect(HoldPolicy.onRelease(heldMs: 5000) == .finish(tailMs: 200))
  }

  @Test func emptyHoldHotkeyTurnsItOff() {
    #expect(HoldPolicy.hotkey("", toggle: nil, pasteOnly: nil) == .ok(nil))
  }

  @Test func anInvalidHoldHotkeyIsRefused() {
    for text in ["banana", "x", "space", "ctrl+", "ctrl+space+f15"] {
      guard case .refused = HoldPolicy.hotkey(text, toggle: nil, pasteOnly: nil) else {
        Issue.record("accepted \(text)")
        continue
      }
    }
  }

  @Test func theToggleShortcutCannotBeTheHoldKey() throws {
    let toggle = try HotkeySpec.parse("ctrl+option+space")
    guard case .refused(let reason) = HoldPolicy.hotkey("ctrl+option+space", toggle: toggle, pasteOnly: nil) else {
      Issue.record("accepted the toggle shortcut"); return
    }
    #expect(reason.contains("dictation shortcut"))
  }

  @Test func theCancelShortcutCannotBeTheHoldKey() {
    guard case .refused(let reason) = HoldPolicy.hotkey("ctrl+escape", toggle: nil, pasteOnly: nil) else {
      Issue.record("accepted ctrl+escape"); return
    }
    #expect(reason.contains("cancels"))
  }

  @Test func thePasteOnlyShortcutCannotBeTheHoldKey() throws {
    let toggle = try HotkeySpec.parse("ctrl+option+space")
    let pasteOnly = PasteOnlyModifier.shift.stopShortcut(for: toggle)
    #expect(pasteOnly == (try? HotkeySpec.parse("ctrl+option+shift+space")))
    guard case .refused(let reason) = HoldPolicy.hotkey("ctrl+option+shift+space", toggle: toggle,
                                                        pasteOnly: pasteOnly) else {
      Issue.record("accepted the paste-only shortcut"); return
    }
    #expect(reason.contains("without sending"))
  }

  @Test func aDistinctShortcutIsAccepted() throws {
    let toggle = try HotkeySpec.parse("ctrl+option+space")
    let pasteOnly = PasteOnlyModifier.shift.stopShortcut(for: toggle)
    #expect(HoldPolicy.hotkey("cmd+option+d", toggle: toggle, pasteOnly: pasteOnly)
      == .ok(try HotkeySpec.parse("cmd+option+d")))
    // A bare F-key is allowed too.
    #expect(HoldPolicy.hotkey("f13", toggle: toggle, pasteOnly: pasteOnly)
      == .ok(try HotkeySpec.parse("f13")))
  }
}
