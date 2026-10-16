import Foundation
import Testing
@testable import KhulumaCore

struct DeliveryTargetTests {
  @Test func neverDeliversToKhulumaItself() {
    #expect(DeliveryTarget.isSelf(frontmostPID: 42, ownPID: 42))
    #expect(!DeliveryTarget.isSelf(frontmostPID: 7, ownPID: 42))
    #expect(!DeliveryTarget.isSelf(frontmostPID: nil, ownPID: 42))
  }

  @Test func aTakeStartedWithKhulumaInFrontIsForTheLastOtherApp() {
    let isSelf = { (app: String) in app == "Khuluma" }
    #expect(DeliveryTarget.original(frontmost: "Ghostty", lastExternal: "Claude", isSelf: isSelf) == "Ghostty")
    #expect(DeliveryTarget.original(frontmost: "Khuluma", lastExternal: "Claude", isSelf: isSelf) == "Claude")
    #expect(DeliveryTarget.original(frontmost: "Khuluma", lastExternal: nil, isSelf: isSelf) == nil)
    #expect(DeliveryTarget.original(frontmost: "Khuluma", lastExternal: "Khuluma", isSelf: isSelf) == nil)
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
    let json = #"{"ok":true,"status":"ok","text":"hi","raw_text":"hi","message":null,"#
      + #""delivery":{"autosend":true,"send_mode":"enter","paste_target":"current","activate_delay_ms":0,"send_delay_ms":35},"#
      + #""timings":{},"usage_deferred":true}"#
    #expect(try JSONDecoder().decode(ProcessResult.self, from: Data(json.utf8)).usageDeferred == true)
  }
}

struct HistorySavedTests {
  private func json(_ tail: String) -> Data {
    Data((#"{"ok":true,"status":"ok","text":"hi","raw_text":"hi","message":null,"#
      + #""delivery":{"autosend":true,"send_mode":"enter","paste_target":"current","activate_delay_ms":0,"send_delay_ms":35},"#
      + #""timings":{},"usage_deferred":true"# + tail + "}").utf8)
  }

  @Test func processResultSaysWhetherHistoryWasSaved() throws {
    #expect(try JSONDecoder().decode(ProcessResult.self, from: json(#","history_saved":true"#)).historySaved)
    #expect(try !JSONDecoder().decode(ProcessResult.self, from: json(#","history_saved":false"#)).historySaved)
  }

  /// A CLI that doesn't report it: the take counts as not recorded, so its
  /// Quit copy is kept.
  @Test func aMissingFieldMeansNotSaved() throws {
    let result = try JSONDecoder().decode(ProcessResult.self, from: json(""))
    #expect(!result.historySaved)
    #expect(result.ok && result.text == "hi" && result.message == nil)
    #expect(!TakeResult.delivered(recorded: result.historySaved).settlesAudio)
  }

  @Test func aNonBooleanFieldIsADecodeError() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ProcessResult.self, from: json(#","history_saved":"yes""#))
    }
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

struct DeliveryAppTests {
  @Test func historyRecordsTheAppTheTextIsDeliveredTo() {
    #expect(DeliveryTarget.deliveryApp(pasteTarget: "current", retargeted: false, original: "Ghostty",
                                       frontmostAtStop: "Safari") == "Safari")
    #expect(DeliveryTarget.deliveryApp(pasteTarget: "restore", retargeted: false, original: "Ghostty",
                                       frontmostAtStop: "Safari") == "Ghostty")
    // Started with Khuluma in front: delivered to Ghostty, so Ghostty.
    #expect(DeliveryTarget.deliveryApp(pasteTarget: "current", retargeted: true, original: "Ghostty",
                                       frontmostAtStop: "Khuluma") == "Ghostty")
    #expect(DeliveryTarget.deliveryApp(pasteTarget: nil, retargeted: false, original: "Ghostty",
                                       frontmostAtStop: "Safari") == "Safari")
  }
}
