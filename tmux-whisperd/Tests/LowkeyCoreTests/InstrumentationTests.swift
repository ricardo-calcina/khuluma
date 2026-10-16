import Foundation
import Testing
@testable import LowkeyCore

struct TakeLogTests {
  @Test func formatsKeyValuePairsAndSkipsNils() {
    var line = TakeLog()
    line.add("path", "native")
    line.add("record", 3200)
    line.add("total", ms: 1911.6)
    line.add("missing", nil as Int?)
    line.add("target", "Google Chrome")
    line.add("error", "said \"no\" \\ twice\nreally")
    line.add("empty", "")
    #expect(line.line
      == #"take: path=native record=3200 total=1912 target="Google Chrome" error="said \"no\" \\ twice really" empty="""#)
  }

  @Test func cliStatusesNeverCarryFreeText() {
    #expect(TakeLog.cliStatus("failed") == "cli_failed")
    #expect(TakeLog.cliStatus("no_speech") == "cli_no_speech")
    #expect(TakeLog.cliStatus("superseded") == "other")
    #expect(TakeLog.cliStatus("Bad output: \"my dictated words\"") == "other")
    #expect(TakeLog.cliStatus("mydictatedwords") == "other")
    #expect(TakeLog.cliStatus(nil) == "other")
  }

  @Test func quotesValuesThatWouldBreakParsing() {
    #expect(TakeLog.quoted("a=b") == #""a=b""#)
    #expect(TakeLog.quoted("tab\there") == #""tab here""#)
    #expect(TakeLog.quoted("Claude") == "Claude")
  }
}

struct TakeDaemonStateTests {
  private func status(loaded: Bool = true, active: Int? = 0, pid: Int? = 1) -> DaemonStatus {
    DaemonStatus(version: "0.3.0", pid: pid, generation: "g",
                 modelLoaded: loaded ? .init(path: "/m", version: "v3") : nil, activeRequests: active)
  }

  @Test func classifiesTheDaemonAtStop() {
    func classify(_ status: DaemonStatus?) -> TakeDaemonState {
      TakeDaemonState.classify(status, modelPath: "/m", modelVersion: "v3")
    }
    #expect(classify(status()) == .warm)
    #expect(classify(status(active: 1)) == .contended)
    #expect(classify(status(loaded: false)) == .cold)
    #expect(classify(nil) == .cold)
    // Before 0.3.0 a daemon reports neither its pid nor its model.
    #expect(classify(DaemonStatus(version: "0.2.0")) == .unknown)
    #expect(TakeDaemonState.classify(status(), modelPath: "/m", modelVersion: "v2") == .cold)
  }

  @Test func probeSettlesOnTheFirstAnswer() {
    let probe = TakeProbe { self.status() }
    #expect(probe.state(waiting: 5, modelPath: "/m", modelVersion: "v3") == .warm)
    #expect(probe.waitedMs < 5000)
  }

  @Test func lateProbeIsUnknownAndStaysSo() {
    let release = DispatchSemaphore(value: 0)
    let answered = DispatchSemaphore(value: 0)
    let probe = TakeProbe {
      release.wait()
      defer { answered.signal() }
      return self.status()
    }
    #expect(probe.state(waiting: 0.01, modelPath: "/m", modelVersion: "v3") == .unknown)
    release.signal()
    answered.wait()
    // The answer came after the take's request was sent: still unknown.
    #expect(probe.state(waiting: 1, modelPath: "/m", modelVersion: "v3") == .unknown)
  }
}

struct TranscriberTimingTests {
  private let settings = TranscriptionSettings(socketPath: "/s", modelPath: "/m")

  @Test func recordsEachPassWithTheDaemonsTime() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      Thread.sleep(forTimeInterval: 0.02)
      return NativeTranscriber.Pass(text: flow == "inline" ? "full" : "tail", daemonMs: flow == "inline" ? 15 : 5)
    })
    let timings = result.timings
    #expect(timings.passes.map(\.flow) == ["inline", "inline-tail"])
    #expect(timings.pass("inline")?.daemonMs == 15)
    #expect(timings.pass("inline-tail")?.daemonMs == 5)
    #expect(timings.passes.allSatisfy { $0.elapsedMs >= 20 })
    #expect(timings.prepMs >= 0 && timings.prepMs < 1000)
  }

  @Test func timesAFailedTailPassWithoutDaemonTime() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      if flow == "inline-tail" { throw DaemonClient.ClientError.daemon(code: "x", message: "y") }
      return NativeTranscriber.Pass(text: "full", daemonMs: 10)
    })
    #expect(result.tailRescueFailed)
    #expect(result.timings.pass("inline-tail")?.daemonMs == nil)
    #expect(result.timings.passes.count == 2)
  }

  @Test func textOnlyTranscribersHaveNoDaemonTime() throws {
    let result = try NativeTranscriber(settings: settings).transcribe(samples: [0.1]) { _, _ in "x" }
    #expect(result.timings.passes.map(\.flow) == ["inline"])
    #expect(result.timings.pass("inline")?.daemonMs == nil)
  }
}

struct DeliveryWaitTests {
  @Test func sumsTheDeliberateWaits() {
    let delivery = Delivery(autosend: true, sendMode: "enter", pasteTarget: "restore",
                            activateDelayMs: 40, sendDelayMs: 35)
    let steps = DeliveryPlan.steps(text: "x", delivery: delivery, hasOriginalApp: true)
    #expect(DeliveryPlan.waitMs(steps) == 40 + DeliveryPlan.minimumSendGapMs)
    let noSend = Delivery(autosend: false, sendMode: "enter", pasteTarget: "current",
                          activateDelayMs: 40, sendDelayMs: 35)
    #expect(DeliveryPlan.waitMs(DeliveryPlan.steps(text: "x", delivery: noSend, hasOriginalApp: true)) == 0)
  }
}
