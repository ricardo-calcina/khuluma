import Foundation
import Testing
@testable import KhulumaCore

struct HotkeyTests {
  @Test func parsesModifiersAndKey() throws {
    let spec = try HotkeySpec.parse("ctrl+option+space")
    #expect(spec.keyCode == 49)
    #expect(spec.carbonModifiers == HotkeySpec.controlMask | HotkeySpec.optionMask)
    #expect(spec.display == "⌃⌥Space")
  }

  @Test func acceptsAliasesCaseAndSpacing() throws {
    let spec = try HotkeySpec.parse(" Cmd + Shift + D ")
    #expect(spec.keyCode == 2)
    #expect(spec.carbonModifiers == HotkeySpec.commandMask | HotkeySpec.shiftMask)
    #expect(spec.display == "⇧⌘D")
  }

  @Test func functionKeysNeedNoModifier() throws {
    let spec = try HotkeySpec.parse("f13")
    #expect(spec.keyCode == 105)
    #expect(spec.display == "F13")
  }

  @Test func rejectsBadInput() {
    #expect(throws: HotkeySpec.ParseError.noModifier) { try HotkeySpec.parse("space") }
    // "F" is a letter, not a function key, despite its label.
    #expect(throws: HotkeySpec.ParseError.noModifier) { try HotkeySpec.parse("f") }
    #expect(throws: HotkeySpec.ParseError.unknownKey("banana")) { try HotkeySpec.parse("ctrl+banana") }
    #expect(throws: HotkeySpec.ParseError.missingKey) { try HotkeySpec.parse("ctrl+option") }
    #expect(throws: HotkeySpec.ParseError.missingKey) { try HotkeySpec.parse("ctrl++space") }
    #expect(throws: HotkeySpec.ParseError.empty) { try HotkeySpec.parse("") }
  }
}

struct WAVEncoderTests {
  @Test func writesA16kMono16BitHeader() {
    let data = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1, -1])
    #expect(data.count == 44 + 5 * 2)
    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    #expect(readLE(UInt16.self, data, 20) == 1)       // PCM
    #expect(readLE(UInt16.self, data, 22) == 1)       // mono
    #expect(readLE(UInt32.self, data, 24) == 16_000)  // sample rate
    #expect(readLE(UInt16.self, data, 34) == 16)      // bits
    #expect(readLE(UInt32.self, data, 40) == 10)      // data bytes
    #expect(readLE(Int16.self, data, 44 + 2) == 16384)
    #expect(readLE(Int16.self, data, 44 + 6) == 32767)
    #expect(readLE(Int16.self, data, 44 + 8) == -32767)
  }

  @Test func clampsAndZeroesNonFiniteSamples() {
    let data = WAVEncoder.encode(samples: [4, -4, .nan])
    #expect(readLE(Int16.self, data, 44) == 32767)
    #expect(readLE(Int16.self, data, 46) == -32767)
    #expect(readLE(Int16.self, data, 48) == 0)
  }

  private func readLE<T: FixedWidthInteger>(_: T.Type, _ data: Data, _ offset: Int) -> T {
    var value: T = 0
    _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size)) }
    return T(littleEndian: value)
  }
}

struct CLIModelTests {
  @Test func decodesAppConfig() throws {
    let config = try AppConfigFixture.decode()
    #expect(config.hotkey == "ctrl+option+space")
    #expect(config.sounds["start"]?.path == "/s/start.wav")
    #expect(config.sounds["cancel"]?.enabled == false)
    #expect(config.inline.sendDelayMs == 35)
    #expect(config.cleanup.configDir == "/c")
  }

  @Test func decodesProcessResult() throws {
    let json = #"""
    {"ok":true,"status":"ok","text":"Hello there.","raw_text":"hello there","mode":"base","message":null,
     "delivery":{"autosend":false,"send_mode":"cmd_enter","paste_target":"restore","activate_delay_ms":90,"send_delay_ms":35},
     "timings":{"transcribe_ms":638,"total_ms":6382},"usage_deferred":true}
    """#
    let result = try JSONDecoder().decode(ProcessResult.self, from: Data(json.utf8))
    #expect(result.ok)
    #expect(result.text == "Hello there.")
    #expect(result.delivery.pasteTarget == "restore")
    #expect(result.timings["transcribe_ms"] == 638)
  }
}

struct DeliveryPlanTests {
  private func delivery(autosend: Bool = true, sendMode: String = "enter", pasteTarget: String = "current",
                        sendDelayMs: Int = 35) -> Delivery {
    Delivery(autosend: autosend, sendMode: sendMode, pasteTarget: pasteTarget, activateDelayMs: 90, sendDelayMs: sendDelayMs)
  }

  @Test func pastesThenPressesEnter() {
    // The default 35 ms is raised to the minimum gap: back to back, the
    // Claude desktop app sometimes takes Enter before the paste.
    let steps = DeliveryPlan.steps(text: "hi", delivery: delivery(), hasOriginalApp: true)
    #expect(steps == [
      .setClipboard("hi"),
      .shortcut(character: "v", command: true, control: false),
      .wait(milliseconds: 150),
      .key(code: 36, command: false, control: false),
    ])
  }

  @Test func sendGapIsNeverShorterThanTheMinimumButLongerDelaysStay() {
    for (configured, expected) in [(0, 150), (35, 150), (150, 150), (400, 400)] {
      let steps = DeliveryPlan.steps(text: "x", delivery: delivery(sendDelayMs: configured), hasOriginalApp: false)
      #expect(steps[2] == .wait(milliseconds: expected), "send_delay_ms \(configured)")
    }
  }

  @Test func restoreReactivatesTheOriginalAppFirst() {
    let steps = DeliveryPlan.steps(text: "hi", delivery: delivery(autosend: false, pasteTarget: "restore"), hasOriginalApp: true)
    #expect(steps == [
      .setClipboard("hi"),
      .activateOriginalApp,
      .wait(milliseconds: 90),
      .shortcut(character: "v", command: true, control: false),
    ])
  }

  @Test func sendModesMapToKeys() {
    let cmd = DeliveryPlan.steps(text: "x", delivery: delivery(sendMode: "cmd_enter"), hasOriginalApp: false)
    #expect(cmd.last == .key(code: 36, command: true, control: false))
    let ctrlJ = DeliveryPlan.steps(text: "x", delivery: delivery(sendMode: "ctrl_j"), hasOriginalApp: false)
    #expect(ctrlJ.last == .shortcut(character: "j", command: false, control: true))
  }

  @Test func restoreWithoutAnOriginalAppJustPastes() {
    let steps = DeliveryPlan.steps(text: "x", delivery: delivery(autosend: false, pasteTarget: "restore"), hasOriginalApp: false)
    #expect(steps == [.setClipboard("x"), .shortcut(character: "v", command: true, control: false)])
  }
}

struct CLIEnvironmentTests {
  @Test func dropsLocaleAndSetsPath() {
    let env = CLIEnvironment.forCLI(
      base: ["LANG": "C.UTF-8", "LC_ALL": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "HOME": "/Users/x",
             "PATH": "/usr/bin", "DICTATE_CLEAN": "1", "LOWKEY_CLI": "/x"],
      home: "/Users/x")
    #expect(env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil)
    #expect(env["HOME"] == "/Users/x" && env["DICTATE_CLEAN"] == "1" && env["LOWKEY_CLI"] == "/x")
    #expect(env["PATH"]?.hasPrefix("/Users/x/.local/bin:/opt/homebrew/bin:") == true)
  }
}
