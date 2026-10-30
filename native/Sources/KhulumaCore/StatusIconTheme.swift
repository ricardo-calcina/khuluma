/// App-only presentation choices for the menu-bar status glyphs.
public enum StatusIconTheme: String, CaseIterable, Hashable, Sendable {
  case cursedSpeech = "cursed-speech"
  case fullEmblem = "full-emblem"

  public init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .cursedSpeech
  }

  public var title: String {
    switch self {
    case .cursedSpeech: return "Cursed speech"
    case .fullEmblem: return "Full emblem"
    }
  }
}

/// App-only choice: the modifier added to the dictation shortcut to finish a
/// take without sending it (paste only), whatever auto-send says.
public enum PasteOnlyModifier: String, CaseIterable, Hashable, Sendable {
  case shift, option, control, command, off

  public init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .shift
  }

  public var title: String {
    switch self {
    case .shift: return "Shift ⇧"
    case .option: return "Option ⌥"
    case .control: return "Control ⌃"
    case .command: return "Command ⌘"
    case .off: return "Off"
    }
  }

  private var mask: UInt32? {
    switch self {
    case .shift: return HotkeySpec.shiftMask
    case .option: return HotkeySpec.optionMask
    case .control: return HotkeySpec.controlMask
    case .command: return HotkeySpec.commandMask
    case .off: return nil
    }
  }

  /// The dictation shortcut plus this modifier. Nil when off, when the
  /// shortcut already holds the modifier (the press is just the shortcut),
  /// or when the result is reserved (Control–Escape cancels, ⌘Q/⌘W).
  public func stopShortcut(for toggle: HotkeySpec) -> HotkeySpec? {
    guard let mask, toggle.carbonModifiers & mask == 0 else { return nil }
    return try? HotkeySpec.parse(HotkeySpec.configText(keyCode: toggle.keyCode,
                                                       carbonModifiers: toggle.carbonModifiers | mask))
  }
}

/// App-only choice: which period the menu's three figures cover.
public enum MenuFigures: String, CaseIterable, Hashable, Sendable {
  case allTime = "all-time"
  case today

  public init(storedValue: String?) {
    self = Self(rawValue: storedValue ?? "") ?? .allTime
  }

  public var title: String {
    switch self {
    case .allTime: return "All time"
    case .today: return "Today"
    }
  }
}
