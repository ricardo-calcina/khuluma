import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import KhulumaCore

/// Executes a DeliveryPlan: clipboard, optional re-activation, and synthetic
/// key presses via CGEvent (needs the Accessibility permission).
enum Deliverer {
  static func isTrusted(prompt: Bool) -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// The post-event check, replaceable in tests.
  nonisolated(unsafe) static var postEventAllowed: () -> Bool = { CGPreflightPostEventAccess() }

  /// Runs on a background queue; waits are real sleeps between steps.
  /// Returns the app that was frontmost when the first key was posted (the
  /// one that received the paste), for the log.
  @discardableResult
  static func perform(_ steps: [DeliveryStep], originalApp: NSRunningApplication?) throws -> String? {
    // The clipboard needs no permission, so the text is never lost: copy it
    // first, then require Accessibility only for activation and key events.
    var remaining = steps[...]
    while case .setClipboard(let text)? = remaining.first {
      DispatchQueue.main.sync {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
      }
      remaining = remaining.dropFirst()
    }
    // A denied or revoked permission fails the delivery: macOS would drop the
    // key events silently and the take would look delivered. The text stays
    // on the clipboard.
    if let failure = PermissionPolicy.deliveryFailure(accessibilityTrusted: isTrusted(prompt: false),
                                                      postEventAllowed: postEventAllowed()) {
      Log.write("deliver: refused, \(failure.code == PermissionPolicy.postEventMissingCode ? "no permission to post key events" : "accessibility not granted")")
      throw failure
    }

    var target: String?
    for step in remaining {
      if target == nil, step.postsKey {
        let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
        // E.g. Khuluma's own window in front: paste and send nothing.
        if DeliveryTarget.isSelf(frontmostPID: front?.processIdentifier, ownPID: getpid()) {
          throw NSError(domain: "Khuluma", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Khuluma was in front: text is on the clipboard",
          ])
        }
        target = front?.localizedName ?? "-"
      }
      switch step {
      case .setClipboard(let text):
        DispatchQueue.main.sync {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      case .activateOriginalApp:
        DispatchQueue.main.sync {
          _ = originalApp?.activate()
        }
      case .wait(let milliseconds):
        usleep(useconds_t(milliseconds * 1000))
      case .shortcut(let character, let command, let control):
        let code = DispatchQueue.main.sync { KeyboardLayout.keyCode(for: character) }
        guard let code else {
          throw NSError(domain: "Khuluma", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "no key types \"\(character)\" in the current keyboard layout: text is on the clipboard",
          ])
        }
        postKey(code: code, command: command, control: control)
      case .key(let code, let command, let control):
        postKey(code: code, command: command, control: control)
      }
    }
    return target
  }

  private static func postKey(code: UInt16, command: Bool, control: Bool) {
    let source = CGEventSource(stateID: .combinedSessionState)
    var flags: CGEventFlags = []
    if command { flags.insert(.maskCommand) }
    if control { flags.insert(.maskControl) }
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }
}

private extension DeliveryStep {
  var postsKey: Bool {
    switch self {
    case .shortcut, .key: true
    case .setClipboard, .activateOriginalApp, .wait: false
    }
  }
}

/// Maps a character to the virtual key that types it in the active keyboard
/// layout (US: v = 9; Dvorak: v = 47), as AppleScript's `keystroke` does.
enum KeyboardLayout {
  static func keyCode(for character: Character) -> UInt16? {
    let target = String(character).lowercased()
    guard
      let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
      return fallback[target]
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
    return layoutData.withUnsafeBytes { raw -> UInt16? in
      guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
      for code in UInt16(0)..<128 {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
          layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
          OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
        )
        if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
          return code
        }
      }
      return fallback[target]
    }
  }

  /// US positions, used only if the layout data is unavailable.
  private static let fallback: [String: UInt16] = ["v": 9, "j": 38]
}
