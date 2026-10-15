import Foundation
import Testing
@testable import LowkeyCore

struct DeliveryTargetTests {
  @Test func neverDeliversToLowkeyItself() {
    #expect(DeliveryTarget.isSelf(frontmostPID: 42, ownPID: 42))
    #expect(!DeliveryTarget.isSelf(frontmostPID: 7, ownPID: 42))
    #expect(!DeliveryTarget.isSelf(frontmostPID: nil, ownPID: 42))
  }

  @Test func aTakeStartedWithLowkeyInFrontIsForTheLastOtherApp() {
    let isSelf = { (app: String) in app == "Lowkey" }
    #expect(DeliveryTarget.original(frontmost: "Ghostty", lastExternal: "Claude", isSelf: isSelf) == "Ghostty")
    #expect(DeliveryTarget.original(frontmost: "Lowkey", lastExternal: "Claude", isSelf: isSelf) == "Claude")
    #expect(DeliveryTarget.original(frontmost: "Lowkey", lastExternal: nil, isSelf: isSelf) == nil)
    #expect(DeliveryTarget.original(frontmost: "Lowkey", lastExternal: "Lowkey", isSelf: isSelf) == nil)
    #expect(DeliveryTarget.original(frontmost: nil as String?, lastExternal: "Claude", isSelf: isSelf) == nil)
  }
}

struct LocalDateTests {
  @Test func isTheGregorianDateInTheGivenZone() throws {
    // 21:30 UTC on 14 Oct is already 15 Oct in Dubai (UTC+4), still 14 Oct in London.
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-14T21:30:00Z"))
    #expect(LocalDate.string(for: instant, timeZone: try #require(TimeZone(identifier: "Asia/Dubai"))) == "2026-10-15")
    #expect(LocalDate.string(for: instant, timeZone: try #require(TimeZone(identifier: "Europe/London"))) == "2026-10-14")
  }
}

struct DeferredUsageTests {
  @Test func processResultSaysWhetherUsageWasDeferred() throws {
    let json = #"{"ok":true,"status":"ok","text":"hi","raw_text":"hi","mode":"base","message":null,"#
      + #""delivery":{"autosend":true,"send_mode":"enter","paste_target":"current","activate_delay_ms":0,"send_delay_ms":35},"#
      + #""timings":{},"usage_deferred":true}"#
    #expect(try JSONDecoder().decode(ProcessResult.self, from: Data(json.utf8)).usageDeferred == true)
  }
}

struct RetargetedDeliveryTests {
  @Test func aRetargetedTakeReactivatesItsAppWhateverThePasteTarget() {
    let current = Delivery(autosend: true, sendMode: "enter", pasteTarget: "current", activateDelayMs: 90, sendDelayMs: 35)
    let steps = DeliveryPlan.steps(text: "hi", delivery: current.restoringOriginalApp(), hasOriginalApp: true)
    #expect(steps.prefix(3) == [.setClipboard("hi"), .activateOriginalApp, .wait(milliseconds: 90)])
    #expect(current.restoringOriginalApp().autosend && current.restoringOriginalApp().sendDelayMs == 35)
  }
}

struct ModeAppTests {
  @Test func modeComesFromTheAppTheTextIsDeliveredTo() {
    #expect(DeliveryTarget.modeApp(pasteTarget: "current", retargeted: false, original: "Ghostty",
                                   frontmostAtStop: "Safari") == "Safari")
    #expect(DeliveryTarget.modeApp(pasteTarget: "restore", retargeted: false, original: "Ghostty",
                                   frontmostAtStop: "Safari") == "Ghostty")
    // Started with Lowkey in front: delivered to Ghostty, so Ghostty's mode.
    #expect(DeliveryTarget.modeApp(pasteTarget: "current", retargeted: true, original: "Ghostty",
                                   frontmostAtStop: "Lowkey") == "Ghostty")
    #expect(DeliveryTarget.modeApp(pasteTarget: nil, retargeted: false, original: "Ghostty",
                                   frontmostAtStop: "Safari") == "Safari")
  }
}
