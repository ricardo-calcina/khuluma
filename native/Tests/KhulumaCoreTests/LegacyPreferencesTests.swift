import Foundation
import Testing
@testable import KhulumaCore

struct LegacyPreferencesTests {
  @Test func importsOnlySupportedSettingsAndRenamesTheFrame() {
    let legacy: [String: Any] = [
      "LowkeyStatsRangeDays": 60,
      "LowkeyStatsMilestoneSeen": 1000,
      "KhulumaStatsWordsPerDay": false,
      "NSWindow Frame LowkeyStats": "20 30 560 640 0 0 1440 900 ",
      "KhulumaOpenStats": true,
      "KhulumaStatsSnapshot": "/private/fixture",
      "KhulumaStatsAppearance": "dark",
      "unrelated": "leave behind",
    ]
    let imported = LegacyPreferences.imports(current: [:], legacy: legacy)
    #expect(Set(imported.keys) == ["KhulumaStatsRangeDays", "KhulumaStatsMilestoneSeen",
                                   "KhulumaStatsWordsPerDay", "NSWindow Frame KhulumaStats"])
    #expect(imported["KhulumaStatsRangeDays"] as? Int == 60)
    #expect(imported["KhulumaStatsWordsPerDay"] as? Bool == false)
    #expect(imported["NSWindow Frame KhulumaStats"] as? String == legacy["NSWindow Frame LowkeyStats"] as? String)
  }

  @Test func canonicalValuesWinIncludingFalseAndZeroAndImportIsRepeatable() {
    var current: [String: Any] = ["KhulumaStatsRangeDays": 0, "KhulumaStatsWordsPerDay": false]
    let legacy: [String: Any] = ["LowkeyStatsRangeDays": 90, "KhulumaStatsWordsPerDay": true,
                               "LowkeyStatsMilestoneSeen": 0]
    let imported = LegacyPreferences.imports(current: current, legacy: legacy)
    #expect(imported.count == 1)
    #expect(imported["KhulumaStatsMilestoneSeen"] as? Int == 0)
    current.merge(imported) { existing, _ in existing }
    #expect(LegacyPreferences.imports(current: current, legacy: legacy).isEmpty)
    #expect(current["KhulumaStatsRangeDays"] as? Int == 0)
    #expect(current["KhulumaStatsWordsPerDay"] as? Bool == false)
  }

  @Test func intermediateDomainSettingsBeatOlderDomainSettings() {
    let imported = LegacyPreferences.imports(
      current: ["LowkeyStatsRangeDays": 30], legacy: ["LowkeyStatsRangeDays": 90])
    #expect(imported["KhulumaStatsRangeDays"] as? Int == 30)
  }
}
