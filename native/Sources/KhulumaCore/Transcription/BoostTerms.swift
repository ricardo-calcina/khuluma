import Foundation

/// A brand term for the speech engine's vocabulary boost: the written form
/// plus other ways it may be heard (experimental, `KHULUMA_BOOST_VOCABULARY`).
public struct BoostTerm: Equatable, Sendable, Codable {
  public var text: String
  public var aliases: [String]
  public init(text: String, aliases: [String] = []) {
    self.text = text
    self.aliases = aliases
  }
}

public enum BoostTerms {
  /// The Brands section as boost terms: one per distinct `write` (first-seen
  /// spelling wins, compared case-insensitively, in first-seen order); its
  /// aliases are the `heard` values of rows sharing that write, minus the
  /// write itself, de-duplicated case-insensitively in order. Writes shorter
  /// than 3 characters or holding `/ @ : \ _` are skipped (too short to spot
  /// reliably, or not spoken text). Words and Fillers are never used.
  public static func from(_ sheet: VocabularySheet) -> [BoostTerm] {
    var seen = Set<String>()
    var writes: [String] = []
    for correction in sheet.brands where seen.insert(correction.write.lowercased()).inserted {
      writes.append(correction.write)
    }
    return writes.compactMap { write in
      guard write.count >= 3,
            write.rangeOfCharacter(from: CharacterSet(charactersIn: "/@:\\_")) == nil else {
        return nil
      }
      var aliasSeen: Set<String> = [write.lowercased()]
      var aliases: [String] = []
      for correction in sheet.brands where correction.write.lowercased() == write.lowercased() {
        if aliasSeen.insert(correction.heard.lowercased()).inserted {
          aliases.append(correction.heard)
        }
      }
      return BoostTerm(text: write, aliases: aliases)
    }
  }
}
