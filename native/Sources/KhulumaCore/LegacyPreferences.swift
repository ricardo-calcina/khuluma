import Foundation

/// The old bundle domain remains intact. Import only supported user settings;
/// diagnostic launch switches and unrelated preferences never cross domains.
public enum LegacyPreferences {
  public static let domain = "com.ricardo-nth.lowkey"
  public static let canonicalDomain = "com.ricardo-nth.khuluma"

  private static let keys = [
    (old: "LowkeyStatsRangeDays", new: "KhulumaStatsRangeDays"),
    (old: "LowkeyStatsMilestoneSeen", new: "KhulumaStatsMilestoneSeen"),
    (old: "KhulumaStatsWordsPerDay", new: "KhulumaStatsWordsPerDay"),
    (old: "NSWindow Frame LowkeyStats", new: "NSWindow Frame KhulumaStats"),
  ]

  /// Values to add, never values to replace. Check presence rather than truth:
  /// false and zero are settings too. A renamed domain may already contain an
  /// old key from an intermediate build, so consult it before the old domain.
  public static func imports(current: [String: Any], legacy: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for key in keys where current[key.new] == nil {
      if let value = current[key.old] ?? legacy[key.new] ?? legacy[key.old] {
        result[key.new] = value
      }
    }
    return result
  }

  /// Called once at ordinary app launch before Stats is constructed. Use the
  /// preferences API, never edit the cached plist or remove the old domain.
  public static func migrate(defaults: UserDefaults = .standard) {
    let current = defaults.persistentDomain(forName: canonicalDomain) ?? [:]
    let legacy = defaults.persistentDomain(forName: domain) ?? [:]
    for (key, value) in imports(current: current, legacy: legacy) {
      defaults.set(value, forKey: key)
    }
  }
}
