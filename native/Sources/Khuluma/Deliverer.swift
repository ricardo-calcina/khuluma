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

  /// The general pasteboard before a dictation overwrites it, per item per
  /// type. Kept whole: restoring means writing every item back.
  private typealias ClipboardSnapshot = [[String: Data]]
  /// A restore still due when another delivery starts: its snapshot is the
  /// user's clipboard (the pasteboard between holds dictation text).
  nonisolated(unsafe) private static var pendingRestore: (snapshot: ClipboardSnapshot, token: Int)?
  nonisolated(unsafe) private static var restoreToken = 0

  /// Snapshots the pasteboard on the main thread. A pending restore's
  /// snapshot is adopted (and the pending one cancelled) so back-to-back
  /// dictations put back the user's own clipboard. nil: nothing to restore
  /// or too large (logged).
  private static func snapshotClipboard() -> ClipboardSnapshot? {
    DispatchQueue.main.sync {
      if let pending = pendingRestore {
        pendingRestore = nil
        return pending.snapshot
      }
      let items = (NSPasteboard.general.pasteboardItems ?? []).map { item -> [String: Data] in
        var types: [String: Data] = [:]
        for type in item.types {
          if let data = item.data(forType: type) { types[type.rawValue] = data }
        }
        return types
      }.filter { !$0.isEmpty }
      let sizes = items.map { $0.values.reduce(0) { $0 + $1.count } }
      switch ClipboardRestore.plan(itemSizes: sizes, limitBytes: DeliveryPlan.clipboardRestoreLimitBytes) {
      case .restore:
        return items
      case .skip(let reason):
        Log.write("deliver: clipboard not restored (\(reason))")
        return nil
      }
    }
  }

  /// Schedules the write-back on the main queue after the delay; it runs
  /// only if the pasteboard still holds what was pasted.
  private static func scheduleRestore(_ snapshot: ClipboardSnapshot, written: Int, afterMs: Int) {
    DispatchQueue.main.async {
      restoreToken += 1
      let token = restoreToken
      pendingRestore = (snapshot, token)
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(afterMs)) {
        guard pendingRestore?.token == token else { return }
        pendingRestore = nil
        let board = NSPasteboard.general
        guard ClipboardRestore.shouldRestore(written: written, current: board.changeCount) else {
          Log.write("deliver: clipboard left alone (changed since paste)")
          return
        }
        board.clearContents()
        board.writeObjects(snapshot.map { types -> NSPasteboardItem in
          let item = NSPasteboardItem()
          for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type)) }
          return item
        })
      }
    }
  }

  /// Runs on a background queue; waits are real sleeps between steps.
  /// Returns the app that was frontmost when the first key was posted (the
  /// one that received the paste), for the log.
  @discardableResult
  static func perform(_ steps: [DeliveryStep], originalApp: NSRunningApplication?) throws -> String? {
    // The clipboard needs no permission, so the text is never lost: copy it
    // first, then require Accessibility only for activation and key events.
    var remaining = steps[...]
    let snapshot = steps.contains { if case .restoreClipboard = $0 { return true }; return false }
      ? snapshotClipboard() : nil
    while case .setClipboard(let text)? = remaining.first {
      DispatchQueue.main.sync {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
      }
      remaining = remaining.dropFirst()
    }
    // The changeCount the restore step compares against.
    let written = snapshot == nil ? 0
      : DispatchQueue.main.sync { NSPasteboard.general.changeCount }
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
      case .restoreClipboard(let afterMs):
        if let snapshot { scheduleRestore(snapshot, written: written, afterMs: afterMs) }
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
    case .setClipboard, .activateOriginalApp, .wait, .restoreClipboard: false
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
