import Foundation
import Testing
@testable import KhulumaCore

/// inline.app_rules decoding, AppRules matching, DeliveryPlan's restore
/// step and the precedence the take applies over the global setting.
struct AppRuleDecodingTests {
  private func decode(_ json: String) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
  }

  @Test func emptyByDefault() throws {
    #expect(try decode("{}").inline.appRules.isEmpty)
    #expect(try decode("{}").inline.restoreClipboard == false)
  }

  @Test func dropsEmptyIdsAndLaterDuplicates() throws {
    let settings = try decode("{\"inline\":{\"app_rules\":["
      + "{\"bundle_id\":\"\",\"name\":\"X\",\"autosend\":true},"
      + "{\"bundle_id\":\"com.a\",\"name\":\"A\",\"autosend\":true},"
      + "{\"bundle_id\":\"COM.A\",\"name\":\"A2\",\"autosend\":false},"
      + "{\"bundle_id\":\"com.b\",\"name\":\"B\",\"autosend\":false}]}}")
    #expect(settings.inline.appRules.map(\.bundleID) == ["com.a", "com.b"])
  }

  @Test func roundTrips() throws {
    var settings = AppSettings()
    settings.inline.appRules = [.init(bundleID: "com.a", name: "A", autosend: false)]
    settings.inline.restoreClipboard = true
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.inline.appRules == settings.inline.appRules)
    #expect(decoded.inline.restoreClipboard)
  }
}

struct AppRulesTests {
  private let rules = [AppSettings.AppRule(bundleID: "Com.A", name: "A", autosend: true),
                       AppSettings.AppRule(bundleID: "com.b", name: "B", autosend: false)]

  @Test func matchesCaseInsensitively() {
    #expect(AppRules.autosend(bundleID: "com.a", default: false, rules: rules) == (true, true))
    #expect(AppRules.autosend(bundleID: "COM.B", default: true, rules: rules) == (false, true))
  }

  @Test func unknownOrMissingIdFallsBackToTheDefault() {
    #expect(AppRules.autosend(bundleID: "com.z", default: true, rules: rules) == (true, false))
    #expect(AppRules.autosend(bundleID: nil, default: false, rules: rules) == (false, false))
  }
}

struct DeliveryPlanRestoreTests {
  private func delivery(restore: Bool = false, autosend: Bool = true,
                        pasteTarget: String = "current") -> Delivery {
    Delivery(autosend: autosend, sendMode: "enter", pasteTarget: pasteTarget,
             activateDelayMs: 90, sendDelayMs: 35, restoreClipboard: restore)
  }

  @Test func restoreStepIsLastWhenOn() {
    let steps = DeliveryPlan.steps(text: "hi", delivery: delivery(restore: true), hasOriginalApp: false)
    #expect(steps.last == .restoreClipboard(afterMs: DeliveryPlan.clipboardRestoreDelayMs))
    // Without autosend, and with a restore-target activation, still last.
    let quiet = DeliveryPlan.steps(text: "hi", delivery: delivery(restore: true, autosend: false),
                                   hasOriginalApp: false)
    #expect(quiet.last == .restoreClipboard(afterMs: DeliveryPlan.clipboardRestoreDelayMs))
    let restore = DeliveryPlan.steps(text: "hi", delivery: delivery(restore: true, pasteTarget: "restore"),
                                     hasOriginalApp: true)
    #expect(restore.contains(.activateOriginalApp))
    #expect(restore.last == .restoreClipboard(afterMs: DeliveryPlan.clipboardRestoreDelayMs))
  }

  @Test func absentWhenOffAndNotAWait() {
    let steps = DeliveryPlan.steps(text: "hi", delivery: delivery(), hasOriginalApp: false)
    #expect(!steps.contains { if case .restoreClipboard = $0 { return true }; return false })
    let restored = DeliveryPlan.steps(text: "hi", delivery: delivery(restore: true), hasOriginalApp: false)
    #expect(DeliveryPlan.waitMs(restored) == DeliveryPlan.waitMs(steps))
  }

  @Test func helpersCarryTheFlag() {
    let base = delivery(restore: true, autosend: true)
    #expect(base.withoutSending().restoreClipboard)
    #expect(base.restoringOriginalApp().restoreClipboard)
    #expect(base.withAutosend(false).restoreClipboard)
    #expect(!base.withAutosend(false).autosend)
  }
}

struct ClipboardRestoreTests {
  @Test func planDecisions() {
    #expect(ClipboardRestore.plan(itemSizes: [], limitBytes: 100) == .skip("empty"))
    #expect(ClipboardRestore.plan(itemSizes: [10, 20], limitBytes: 100) == .restore)
    #expect(ClipboardRestore.plan(itemSizes: [200], limitBytes: 100) == .skip("too_large"))
  }

  @Test func restoresOnlyWhenUnchanged() {
    #expect(ClipboardRestore.shouldRestore(written: 5, current: 5))
    #expect(!ClipboardRestore.shouldRestore(written: 5, current: 6))
  }
}

/// The precedence `Take.ruledDelivery` implements: fallback defaults beat a
/// rule, paste-only beats a rule, a rule beats the global switch.
struct AppRulePrecedenceTests {
  private func make(autosend: Bool, source: String = "file") -> AppConfig {
    var settings = AppSettings()
    settings.inline.autosend = autosend
    settings.inline.appRules = [.init(bundleID: "com.send", name: "S", autosend: true),
                                .init(bundleID: "com.nosend", name: "N", autosend: false)]
    return AppConfig(settings: settings,
                     status: AppConfig.ConfigStatus(error: source == "defaults" ? "x" : nil, source: source),
                     environment: SettingsEnvironment(
                       appFolder: URL(fileURLWithPath: "/tmp"), home: "/tmp", soundsDir: "/tmp",
                       modelsDir: "/tmp", defaultSocketPath: "/tmp/x.sock", ffmpegAvailable: true,
                       keyAvailable: false))
  }

  @Test func fallbackDefaultsBeatASendRule() {
    let cfg = make(autosend: true, source: "defaults")
    #expect(cfg.usingFallbackDefaults)
    // safeDelivery already forced autosend off; the rule must not lift it.
    #expect(!cfg.delivery.autosend)
    let ruled = AppRules.autosend(bundleID: "com.send", default: cfg.delivery.autosend,
                                rules: cfg.inline.appRules)
    #expect(ruled.matched) // a rule exists, but ruledDelivery skips it under fallback
  }

  @Test func pasteOnlyBeatsASendRule() {
    let cfg = make(autosend: false)
    let ruled = AppRules.autosend(bundleID: "com.send", default: cfg.delivery.autosend,
                                rules: cfg.inline.appRules)
    let delivery = cfg.delivery.withAutosend(ruled.autosend).withoutSending()
    #expect(!delivery.autosend)
  }

  @Test func rulesBeatTheGlobalSwitch() {
    let cfg = make(autosend: true)
    #expect(AppRules.autosend(bundleID: "com.nosend", default: cfg.delivery.autosend,
                            rules: cfg.inline.appRules) == (false, true))
    let off = make(autosend: false)
    #expect(AppRules.autosend(bundleID: "com.send", default: off.delivery.autosend,
                            rules: off.inline.appRules) == (true, true))
  }
}

struct AppRuleStoreTests {
  private func scratch() throws -> SettingsStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("khuluma-rules-\(UUID().uuidString)", isDirectory: true)
    return SettingsStore(folder: root)
  }

  @Test func setAppRulesRoundTripsAndKeepsOtherKeys() throws {
    let store = try scratch(); defer { try? FileManager.default.removeItem(at: store.folder) }
    _ = try store.set("inline.autosend", value: "false")
    try store.setAppRules([.init(bundleID: "com.a", name: "A", autosend: true)])
    let loaded = store.load().settings
    #expect(loaded.inline.appRules == [.init(bundleID: "com.a", name: "A", autosend: true)])
    #expect(!loaded.inline.autosend)
  }

  @Test func setAppRulesValidates() throws {
    let store = try scratch(); defer { try? FileManager.default.removeItem(at: store.folder) }
    #expect(throws: (any Error).self) { try store.setAppRules([.init(bundleID: "", name: "A", autosend: true)]) }
    #expect(throws: (any Error).self) { try store.setAppRules([.init(bundleID: "com.a", name: "", autosend: true)]) }
    #expect(throws: (any Error).self) {
      try store.setAppRules([.init(bundleID: "com.a", name: "A", autosend: true),
                             .init(bundleID: "COM.A", name: "B", autosend: true)]) }
    #expect(throws: (any Error).self) {
      try store.setAppRules((0..<101).map { .init(bundleID: "com.\($0)", name: "x", autosend: true) }) }
  }

  @Test func restoreClipboardKeySetsAndReads() throws {
    let store = try scratch(); defer { try? FileManager.default.removeItem(at: store.folder) }
    _ = try store.set("inline.restore_clipboard", value: "true")
    #expect(store.load().settings.inline.restoreClipboard)
    _ = try store.set("inline.restore_clipboard", value: "0")
    #expect(!store.load().settings.inline.restoreClipboard)
  }
}
