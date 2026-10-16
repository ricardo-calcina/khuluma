import Foundation

/// A global hotkey parsed from config text such as `"ctrl+option+space"`.
///
/// Values are Carbon virtual key codes and Carbon modifier masks, so the app
/// can pass them straight to `RegisterEventHotKey`.
public struct HotkeySpec: Equatable, Sendable {
  public let keyCode: UInt32
  public let carbonModifiers: UInt32
  /// Human-readable form for the menu, e.g. "⌃⌥Space".
  public let display: String

  // Carbon modifier masks (Events.h), duplicated to keep this target free of
  // Carbon imports.
  public static let commandMask: UInt32 = 0x0100
  public static let shiftMask: UInt32 = 0x0200
  public static let optionMask: UInt32 = 0x0800
  public static let controlMask: UInt32 = 0x1000

  public enum ParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownModifier(String)
    case unknownKey(String)
    case missingKey
    case noModifier

    public var description: String {
      switch self {
      case .empty: return "hotkey is empty"
      case .unknownModifier(let m): return "unknown modifier \"\(m)\" (use ctrl, option, shift, cmd)"
      case .unknownKey(let k): return "unknown key \"\(k)\""
      case .missingKey: return "hotkey has modifiers but no key"
      case .noModifier: return "hotkey needs at least one modifier (except F-keys)"
      }
    }
  }

  public static func parse(_ text: String) throws -> HotkeySpec {
    let parts = text
      .lowercased()
      .split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard !(parts.count == 1 && parts[0].isEmpty) else { throw ParseError.empty }

    var modifiers: UInt32 = 0
    var key: (code: UInt32, label: String)?
    for part in parts {
      guard !part.isEmpty else { throw ParseError.missingKey }
      if let mask = modifierMasks[part] {
        modifiers |= mask
        continue
      }
      guard key == nil, let found = keyCodes[part] else {
        if key != nil { throw ParseError.unknownModifier(part) }
        throw ParseError.unknownKey(part)
      }
      key = found
    }
    guard let key else { throw ParseError.missingKey }
    // A bare key would hijack normal typing; only F1-F20 may stand alone.
    if modifiers == 0 && !functionKeyCodes.contains(key.code) {
      throw ParseError.noModifier
    }

    var display = ""
    if modifiers & controlMask != 0 { display += "⌃" }
    if modifiers & optionMask != 0 { display += "⌥" }
    if modifiers & shiftMask != 0 { display += "⇧" }
    if modifiers & commandMask != 0 { display += "⌘" }
    display += key.label
    return HotkeySpec(keyCode: key.code, carbonModifiers: modifiers, display: display)
  }

  static let modifierMasks: [String: UInt32] = [
    "ctrl": controlMask, "control": controlMask, "⌃": controlMask,
    "option": optionMask, "opt": optionMask, "alt": optionMask, "⌥": optionMask,
    "shift": shiftMask, "⇧": shiftMask,
    "cmd": commandMask, "command": commandMask, "⌘": commandMask,
  ]

  static let functionKeyCodes: Set<UInt32> = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    105, 107, 113, 106, 64, 79, 80, 90,
  ]

  // ANSI virtual key codes (HIToolbox/Events.h).
  static let keyCodes: [String: (code: UInt32, label: String)] = {
    var map: [String: (UInt32, String)] = [
      "space": (49, "Space"), "return": (36, "Return"), "enter": (36, "Return"),
      "tab": (48, "Tab"), "escape": (53, "Esc"), "esc": (53, "Esc"),
      "delete": (51, "Delete"), "backspace": (51, "Delete"),
      "`": (50, "`"), "grave": (50, "`"), "-": (27, "-"), "=": (24, "="),
      "[": (33, "["), "]": (30, "]"), "\\": (42, "\\"), ";": (41, ";"),
      "'": (39, "'"), ",": (43, ","), ".": (47, "."), "/": (44, "/"),
      "left": (123, "←"), "right": (124, "→"), "down": (125, "↓"), "up": (126, "↑"),
    ]
    let letters: [(String, UInt32)] = [
      ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
      ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
      ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
      ("j", 38), ("k", 40), ("n", 45), ("m", 46),
    ]
    for (letter, code) in letters { map[letter] = (code, letter.uppercased()) }
    let digits: [(String, UInt32)] = [
      ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23),
      ("9", 25), ("7", 26), ("8", 28), ("0", 29),
    ]
    for (digit, code) in digits { map[digit] = (code, digit) }
    let functionKeys: [UInt32] = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
      105, 107, 113, 106, 64, 79, 80, 90,
    ]
    for (index, code) in functionKeys.enumerated() {
      map["f\(index + 1)"] = (code, "F\(index + 1)")
    }
    return map.mapValues { (code: $0.0, label: $0.1) }
  }()
}
