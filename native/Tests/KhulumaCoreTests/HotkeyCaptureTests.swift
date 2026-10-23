import Testing
@testable import KhulumaCore

struct HotkeyCaptureTests {
  @Test func capturesPhysicalKeyAndCanonicalModifierOrder() throws {
    let modifiers = HotkeySpec.commandMask | HotkeySpec.optionMask | HotkeySpec.controlMask | HotkeySpec.shiftMask
    let text = try HotkeySpec.configText(keyCode: 2, carbonModifiers: modifiers)
    #expect(text == "ctrl+option+shift+cmd+d")
    let parsed = try HotkeySpec.parse(text)
    #expect(parsed.keyCode == 2)
    #expect(parsed.carbonModifiers == modifiers)
    #expect(parsed.display == "⌃⌥⇧⌘D")
  }

  @Test func functionKeysCanStandAlone() throws {
    #expect(try HotkeySpec.configText(keyCode: 105, carbonModifiers: 0) == "f13")
    #expect(try HotkeySpec.configText(keyCode: 90, carbonModifiers: 0) == "f20")
  }

  @Test func normalTypingKeysNeedModifiers() {
    #expect(throws: HotkeySpec.ParseError.noModifier) {
      try HotkeySpec.configText(keyCode: 0, carbonModifiers: 0)
    }
    #expect(throws: HotkeySpec.ParseError.noModifier) {
      try HotkeySpec.configText(keyCode: 49, carbonModifiers: 0)
    }
  }

  @Test func preservesSpecialKeyNamesWithoutAmbiguousAliases() throws {
    #expect(try HotkeySpec.configText(keyCode: 36, carbonModifiers: HotkeySpec.controlMask) == "ctrl+return")
    #expect(try HotkeySpec.configText(keyCode: 51, carbonModifiers: HotkeySpec.optionMask) == "option+delete")
    #expect(try HotkeySpec.configText(keyCode: 50, carbonModifiers: HotkeySpec.commandMask) == "cmd+grave")
    #expect(try HotkeySpec.configText(keyCode: 53, carbonModifiers: HotkeySpec.optionMask) == "option+escape")
  }

  @Test func rejectsCancellationAndAppWindowShortcuts() {
    #expect(throws: HotkeySpec.CaptureError.reservedShortcut("⌃Esc")) {
      try HotkeySpec.configText(keyCode: 53, carbonModifiers: HotkeySpec.controlMask)
    }
    #expect(throws: HotkeySpec.CaptureError.reservedShortcut("⌘Q")) {
      try HotkeySpec.configText(keyCode: 12, carbonModifiers: HotkeySpec.commandMask)
    }
    #expect(throws: HotkeySpec.CaptureError.reservedShortcut("⇧⌘W")) {
      try HotkeySpec.configText(keyCode: 13, carbonModifiers: HotkeySpec.commandMask | HotkeySpec.shiftMask)
    }
  }

  @Test func rejectsUnsupportedPhysicalKeysAndModifierBits() {
    #expect(throws: HotkeySpec.CaptureError.unsupportedKeyCode(999)) {
      try HotkeySpec.configText(keyCode: 999, carbonModifiers: HotkeySpec.controlMask)
    }
    #expect(throws: HotkeySpec.CaptureError.unsupportedModifiers(0x8000)) {
      try HotkeySpec.configText(keyCode: 0, carbonModifiers: HotkeySpec.controlMask | 0x8000)
    }
  }

  @Test func everySupportedPhysicalKeyRoundTrips() throws {
    for keyCode in Set(HotkeySpec.keyCodes.values.map(\.code)) {
      let text = try HotkeySpec.configText(keyCode: keyCode, carbonModifiers: HotkeySpec.optionMask)
      let spec = try HotkeySpec.parse(text)
      #expect(spec.keyCode == keyCode)
      #expect(spec.carbonModifiers == HotkeySpec.optionMask)
    }
  }
}
