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
