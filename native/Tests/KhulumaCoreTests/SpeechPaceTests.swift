import Foundation
import Testing
@testable import KhulumaCore
import KhulumaDaemonKit

struct SpeechTimeTests {
  @Test func emptyAndInvalidAreUnknown() {
    #expect(SpeechTime.speechMs(spans: []) == nil)
    #expect(SpeechTime.speechMs(spans: [[500, 100], [-10, 50], [1]]) == nil)
  }

  @Test func singleWordIsItsSpan() {
    #expect(SpeechTime.speechMs(spans: [[200, 650]]) == 450)
  }

  @Test func overlapsMergeAndOrderDoesNotMatter() {
    #expect(SpeechTime.speechMs(spans: [[300, 800], [0, 500], [600, 700]]) == 800)
  }

  @Test func gapsAtOrBelowTheThresholdCountAndLongerOnesDont() {
    // 1000 ms gap counts, 1001 ms gap is a pause.
    #expect(SpeechTime.speechMs(spans: [[0, 500], [1500, 2000]]) == 2000)
    #expect(SpeechTime.speechMs(spans: [[0, 500], [1501, 2001]]) == 1000)
    #expect(SpeechTime.speechMs(spans: [[0, 500], [800, 1000]]) == 1000)
    #expect(SpeechTime.speechMs(spans: [[0, 500], [1501, 2001]], pauseThresholdMs: 1500) == 2001)
  }

  @Test func invalidSpansAreDroppedAmongValidOnes() {
    #expect(SpeechTime.speechMs(spans: [[1000, 900], [0, 400], [-5, 10], [600, 900]]) == 900)
  }
}

private actor SpanDaemon: DaemonRequestHandling {
  func handle(_ request: DaemonRequest) async -> DaemonResponse {
    if request.op == .ping { return DaemonResponse(id: request.id, ok: true, version: DaemonInfo.daemonVersion) }
    let spans: [[Int]]? = request.flow == "inline" ? [[0, 500], [700, 1000], [5000, 5600]] : [[0, 9000]]
    return DaemonResponse(id: request.id, ok: true, text: "word", durationMs: 1, wordSpansMs: spans)
  }
}

struct SpeechPaceTranscriptionTests {
  private let settings = TranscriptionSettings(socketPath: "/s", modelPath: "/m")

  @Test func clientCarriesWordSpans() async throws {
    let path = NSTemporaryDirectory() + "khuluma-\(UUID().uuidString.prefix(8)).sock"
    let server = UnixSocketServer(socketPath: path, handler: SpanDaemon())
    try server.start()
    defer { server.stop() }
    let client = DaemonClient(socketPath: path)
    let pass = try await withCheckedThrowingContinuation { (c: CheckedContinuation<NativeTranscriber.Pass, Error>) in
      DispatchQueue.global().async {
        c.resume(with: Result {
          try client.transcribePass(wav: URL(fileURLWithPath: "/tmp/a.wav"), language: "en", flow: "inline",
                                    modelPath: "/m", modelVersion: "v3", timeout: 5)
        })
      }
    }
    #expect(pass.wordSpansMs == [[0, 500], [700, 1000], [5000, 5600]])
  }

  @Test func speechIgnoresAFailedTailPass() throws {
    // 13 s: long enough for a tail pass; it fails, so only inline time counts.
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      if flow != "inline" { throw DaemonClient.ClientError.daemon(code: "x", message: "y") }
      return NativeTranscriber.Pass(text: "x", wordSpansMs: [[0, 500], [700, 1000], [5000, 5600]])
    })
    #expect(result.timings.passes.count == 2)
    #expect(result.speechMs == 1600)
  }

  @Test func noSpansMeansUnknown() throws {
    let result = try NativeTranscriber(settings: settings).transcribe(samples: [0.1]) { _, _ in "x" }
    #expect(result.speechMs == nil)
  }

  @Test func scribeWordsGiveSpeechTime() {
    let words: [[String: Any]] = [
      ["text": "hello", "start": 0.1, "end": 0.5, "type": "word"],
      ["text": " ", "start": 0.5, "end": 3.0, "type": "spacing"],
      ["text": "(laughs)", "start": 1.0, "end": 2.0, "type": "audio_event"],
      ["text": "there", "start": 3.0, "end": 3.4, "type": "word"],
    ]
    #expect(ScribeClient.speechMs(words: words) == 800)
    #expect(ScribeClient.speechMs(words: nil) == nil)
    #expect(ScribeClient.speechMs(words: "odd") == nil)
    #expect(ScribeClient.speechMs(words: [["type": "word", "start": "x"]]) == nil)
  }

  @Test func scribeTextUnchangedWithOrWithoutWords() throws {
    let fake = FakeScribeTransport()
    let client = ScribeClient(credential: ScribeCredential(keychain: MemoryKeychain("k"), environment: [:],
                                                           home: URL(fileURLWithPath: "/nonexistent")),
                              transport: fake.transport)
    let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s-\(UUID().uuidString).wav")
    try WAVEncoder.encode(samples: [Float](repeating: 0.1, count: 1600)).write(to: wav)
    defer { try? FileManager.default.removeItem(at: wav) }
    let plain = try client.transcribeMeasured(wav: wav, language: "en")
    #expect(plain == ScribeClient.Transcript(text: "hello there", speechMs: nil))
    #expect(try client.transcribe(wav: wav, language: "en") == "hello there")
    fake.body = Data(#"{"text":"hi","words":[{"text":"hi","start":0.2,"end":0.6,"type":"word"}]}"#.utf8)
    #expect(try client.transcribeMeasured(wav: wav, language: "en") == ScribeClient.Transcript(text: "hi", speechMs: 400))
  }

  @Test func oldTakeRecordDecodesWithoutSpeech() throws {
    let json = #"{"take_id":"a","status":"ok","delivered":true,"raw_text":"","text":"hi","record_ms":10,"transcribe_ms":0,"clean_ms":0,"paste_ms":0,"total_ms":0,"startup_ms":0,"startup_source":"app:native"}"#
    let record = try JSONDecoder().decode(TakeRecord.self, from: Data(json.utf8))
    #expect(record.speechMs == nil)
    var measured = record
    measured.speechMs = 7
    let data = try JSONEncoder().encode(measured)
    #expect(String(decoding: data, as: UTF8.self).contains(#""speech_ms":7"#))
  }
}

private func tempRoot() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pace-\(UUID().uuidString)", isDirectory: true)
}

private let fixedNow = Date(timeIntervalSince1970: 1_793_870_042)  // 2026-11-05

struct SpeechPaceStorageTests {
  private func recorder(_ root: URL) -> TakeRecorder {
    var r = TakeRecorder(root: root, settings: .init(keepLogs: false), now: { fixedNow },
                         temporaryRoots: [root.appendingPathComponent("tmp")])
    r.timeZone = TimeZone(identifier: "UTC")!
    return r
  }

  private func historyText(_ r: TakeRecorder) throws -> String {
    let names = try FileManager.default.contentsOfDirectory(atPath: r.historyDirectory.path).filter { $0.hasSuffix(".json") }
    return try names.map { try String(contentsOf: r.historyDirectory.appendingPathComponent($0), encoding: .utf8) }.joined()
  }

  @Test func historyHasSpeechOnlyWhenKnown() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let r = recorder(root)
    let pending = PendingRecords(directory: root.appendingPathComponent("pending", isDirectory: true))
    var record = TakeRecord(takeId: "known1", status: "ok", delivered: true)
    record.text = "hello there"
    record.recordMs = 5000
    record.speechMs = 9000  // clamped to record_ms
    _ = r.apply(PendingTake(record: record), spooled: nil, pending: pending)
    let text = try historyText(r)
    #expect(text.contains("\"speech_ms\""))
    #expect(text.range(of: #""record_ms"\s*:\s*5000,\s*"speech_ms"\s*:\s*5000"#, options: .regularExpression) != nil)

    let root2 = tempRoot()
    defer { try? FileManager.default.removeItem(at: root2) }
    let r2 = recorder(root2)
    record.takeId = "unknown1"
    record.speechMs = nil
    _ = r2.apply(PendingTake(record: record), spooled: nil, pending: pending)
    #expect(!(try historyText(r2)).contains("speech_ms"))
  }

  private func ledger(_ url: URL) -> UsageLedger {
    UsageLedger(url: url, now: { fixedNow }, timeZone: TimeZone(identifier: "UTC")!)
  }

  private func load(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  }

  private func writeOld(_ url: URL, bucketPause: Any? = nil, totalPause: Any? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var bucket: [String: Any] = ["count": 1, "inline": 1, "tmux": 0, "words": 10, "recording_ms": 4000,
                                 "full_elapsed_ms": 5000, "longest_recording_ms": 4000, "most_words": 10]
    if let bucketPause { bucket["pause_ms"] = bucketPause }
    var payload: [String: Any] = [
      "schema_version": 1, "tracking_started_at": "2026-10-01T00:00:00Z",
      "delivered_dictations": ["count": 1, "by_flow": ["inline": 1, "tmux": 0]],
      "processed_words": 10, "recording_duration_ms": 4000, "full_elapsed_duration_ms": 5000,
      "custom_key": "kept",
      "daily": ["started_at": "2026-10-01T00:00:00Z", "baseline_count": 0, "days": ["2026-11-05": bucket]],
    ]
    if let totalPause { payload["pause_duration_ms"] = totalPause }
    try JSONSerialization.data(withJSONObject: payload).write(to: url)
  }

  @Test func oldFileRecordsAMeasuredTake() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("usage.json")
    try writeOld(url)
    _ = try ledger(url).record(.init(text: "one two three", recordMs: 10_000, fullElapsedMs: 11_000,
                                     takeId: "m1", speechMs: 6_000))
    let out = try load(url)
    #expect(out["pause_duration_ms"] as? Int == 4_000)
    #expect(out["custom_key"] as? String == "kept")
    let day = ((out["daily"] as! [String: Any])["days"] as! [String: Any])["2026-11-05"] as! [String: Any]
    #expect(day["pause_ms"] as? Int == 4_000)
    #expect(day["count"] as? Int == 2)
    // Speech longer than the recording is clamped: no negative pause.
    _ = try ledger(url).record(.init(text: "x", recordMs: 1_000, fullElapsedMs: 1_000, takeId: "m2", speechMs: 5_000))
    #expect(try load(url)["pause_duration_ms"] as? Int == 4_000)
  }

  @Test func unmeasuredTakeAddsNoPauseFields() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("usage.json")
    try writeOld(url)
    _ = try ledger(url).record(.init(text: "one", recordMs: 1_000, fullElapsedMs: 1_000, takeId: "u1"))
    let out = try load(url)
    #expect(out["pause_duration_ms"] == nil)
    let day = ((out["daily"] as! [String: Any])["days"] as! [String: Any])["2026-11-05"] as! [String: Any]
    #expect(day["pause_ms"] == nil)
    #expect(day["count"] as? Int == 2)
  }

  @Test func malformedPauseFieldsAreLeftAloneAndTheTakeStillCounts() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("usage.json")
    try writeOld(url, bucketPause: "bad", totalPause: -3)
    var warnings: [String] = []
    _ = try ledger(url).record(.init(text: "one", recordMs: 2_000, fullElapsedMs: 2_000, takeId: "b1", speechMs: 500)) {
      warnings.append($0)
    }
    let out = try load(url)
    #expect(out["pause_duration_ms"] as? Int == -3)
    let day = ((out["daily"] as! [String: Any])["days"] as! [String: Any])["2026-11-05"] as! [String: Any]
    #expect(day["pause_ms"] as? String == "bad")
    #expect(day["count"] as? Int == 2)
    #expect(warnings.count == 2)
    // The report still reads it, treating the bad values as no pauses.
    let report = try UsageReportBuilder.report(url: url, today: CivilDate("2026-11-05")!)
    #expect(report.daily?.status == "active")
    #expect(report.pauseMs == 0 && report.daily?.days.first?.pauseMs == 0)
  }

  @Test func reportReadsOldAndNewFiles() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("usage.json")
    try writeOld(url)
    let old = try UsageReportBuilder.report(url: url, today: CivilDate("2026-11-05")!)
    #expect(old.pauseMs == 0 && old.daily?.days.first?.pauseMs == 0)
    #expect(old.estimatedTimeDifferenceMs == 10 * 60_000 / 40 - 5_000)
    try writeOld(url, bucketPause: 1_000, totalPause: 1_000)
    let new = try UsageReportBuilder.report(url: url, today: CivilDate("2026-11-05")!)
    #expect(new.pauseMs == 1_000 && new.daily?.days.first?.pauseMs == 1_000)
    #expect(new.estimatedTimeDifferenceMs == 10 * 60_000 / 40 - 4_000)
  }
}

struct SpeechPaceStatsTests {
  private func stats(pause: Int, dayPause: Int) -> UsageStats {
    let today = CivilDate("2026-11-05")!
    let days = [
      UsageReport.Day(date: today, count: 2, words: 300, recordingMs: 120_000, fullElapsedMs: 130_000, pauseMs: dayPause),
      UsageReport.Day(date: today.adding(days: -1), count: 1, words: 150, recordingMs: 60_000, fullElapsedMs: 62_000),
    ]
    let report = UsageReport(trackingStartedAt: nil, dictations: 3, words: 450, recordingMs: 180_000,
                             fullElapsedMs: 192_000, typingWPM: 40, estimatedTimeDifferenceMs: 0,
                             daily: .init(status: "active", startedAt: nil, asOfLocalDate: today,
                                          untrackedDeliveries: 0, days: days),
                             pauseMs: pause)
    return UsageStats(report: report, today: today, timeZone: TimeZone(identifier: "UTC")!)
  }

  @Test func everyWPMLeavesOutMeasuredPauses() {
    let s = stats(pause: 60_000, dayPause: 60_000)
    #expect(s.lifetime.wordsPerMinute == 225)  // 450 / 2 min
    #expect(s.figures(.today).wordsPerMinute == 300)  // 300 / 1 min
    #expect(s.range(days: 7).wordsPerMinute == 225)
    let cells = s.lastDays(2)
    #expect(cells.map(\.wordsPerMinute) == [150, 300])
  }

  @Test func oldDataKeepsItsFigure() {
    let s = stats(pause: 0, dayPause: 0)
    #expect(s.lifetime.wordsPerMinute == 150)
    #expect(s.figures(.today).wordsPerMinute == 150)
  }

  @Test func denominatorNeverBelowOneSecond() {
    #expect(UsageStats.wpm(words: 10, recordingMs: 5_000, pauseMs: 5_000) == 600)
    #expect(UsageStats.wpm(words: 10, recordingMs: 0, pauseMs: 0) == nil)
  }

  @Test func todaySavedLeavesOutPauses() {
    // 300 words at 40 wpm = 450 s typing; 130 s elapsed less 60 s pauses.
    #expect(stats(pause: 0, dayPause: 60_000).figures(.today).estimatedSavedMs == 450_000 - 70_000)
    #expect(stats(pause: 0, dayPause: 0).figures(.today).estimatedSavedMs == 450_000 - 130_000)
  }
}

struct SpeechPaceRobustnessTests {
  private func ledgerURL(_ bucketPause: Any?, _ totalPause: Any?) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("usage.json")
    var bucket: [String: Any] = ["count": 1, "inline": 1, "tmux": 0, "words": 1, "recording_ms": 1, "full_elapsed_ms": 1,
                                 "longest_recording_ms": 1, "most_words": 1]
    bucket["pause_ms"] = bucketPause
    let payload: [String: Any] = [
      "schema_version": 1, "delivered_dictations": ["count": 1, "by_flow": ["inline": 1, "tmux": 0]],
      "pause_duration_ms": totalPause as Any,
      "daily": ["started_at": "2026-10-01T00:00:00Z", "baseline_count": 0, "days": ["2026-11-05": bucket]],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: url)
    return url
  }

  @Test func pauseNearIntMaxDoesNotTrapAndTheTakeCounts() throws {
    let url = try ledgerURL(Int.max - 1, Int.max - 1)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var warnings: [String] = []
    let ledger = UsageLedger(url: url, now: { Date(timeIntervalSince1970: 1_793_870_042) },
                             timeZone: TimeZone(identifier: "UTC")!)
    let outcome = try ledger.record(.init(text: "a b", recordMs: 5_000, fullElapsedMs: 5_000, takeId: "o1",
                                          speechMs: 1_000)) { warnings.append($0) }
    #expect(outcome == .recorded(words: 2))
    let out = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect((out["pause_duration_ms"] as? NSNumber)?.int64Value == Int64(Int.max - 1))
    let day = ((out["daily"] as! [String: Any])["days"] as! [String: Any])["2026-11-05"] as! [String: Any]
    #expect((day["pause_ms"] as? NSNumber)?.int64Value == Int64(Int.max - 1))
    #expect(day["count"] as? Int == 2)
    #expect(warnings.count == 2)
  }

  @Test func badSpeechMsInASpooledRecordReadsAsUnknown() throws {
    for bad in [#""bad""#, "1e40", "99999999999999999999999", "-5", "null"] {
      let json = #"{"take_id":"a","status":"ok","delivered":true,"raw_text":"","text":"hi","record_ms":10,"transcribe_ms":0,"clean_ms":0,"paste_ms":0,"total_ms":0,"startup_ms":0,"startup_source":"app:native","speech_ms":"# + bad + "}"
      let record = try JSONDecoder().decode(TakeRecord.self, from: Data(json.utf8))
      #expect(record.speechMs == nil && record.text == "hi")
    }
    var record = TakeRecord(takeId: "a", status: "ok", delivered: true)
    #expect(!String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("speech_ms"))
    record.speechMs = 42
    let back = try JSONDecoder().decode(TakeRecord.self, from: JSONEncoder().encode(record))
    #expect(back.speechMs == 42 && back == record)
  }

  @Test func malformedWordSpansStillGiveTheText() throws {
    for spans in [#""x""#, #"[[1,"a"]]"#, "[[1e40,2]]"] {
      let body = #"{"id":"1","ok":true,"text":"hello","word_spans_ms":"# + spans + "}"
      let response = try JSONDecoder().decode(DaemonClient.Response.self, from: Data(body.utf8))
      #expect(response.text == "hello" && response.wordSpansMs == nil)
    }
  }

  @Test func hugeScribeTimestampsAreDropped() {
    let words: [[String: Any]] = [
      ["type": "word", "start": 1e20, "end": 1e20 + 1],
      ["type": "word", "start": 0.0, "end": 0.5],
    ]
    #expect(ScribeClient.speechMs(words: words) == 500)
    #expect(ScribeClient.speechMs(words: [["type": "word", "start": 1e20, "end": 2e20]]) == nil)
  }

  private let settings = TranscriptionSettings(socketPath: "/s", modelPath: "/m")

  @Test func mergedTailWordsAddTheirTime() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    var tailWindow = 0
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { url, flow in
      if flow == "inline" { return NativeTranscriber.Pass(text: "one two", wordSpansMs: [[0, 1000]]) }
      return NativeTranscriber.Pass(text: "two three", wordSpansMs: [[0, 500]])
    })
    tailWindow = try #require(result.tailRescueMs)
    let offset = (result.paddedSamples - tailWindow * AudioPrep.sampleRate / 1000) * 1000 / AudioPrep.sampleRate
    #expect(result.speechMs == SpeechTime.speechMs(spans: [[0, 1000], [offset, offset + 500]]))
    #expect(result.speechMs == 1500)
  }

  @Test func mergedTailWithoutSpansIsUnknown() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      flow == "inline" ? NativeTranscriber.Pass(text: "one two", wordSpansMs: [[0, 1000]])
        : NativeTranscriber.Pass(text: "two three")
    })
    #expect(result.speechMs == nil)
  }

  @Test func absurdSpansNeverTrap() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    // Absurd tail spans are dropped; with none left the merged tail is untimed.
    let tailBad = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      flow == "inline" ? NativeTranscriber.Pass(text: "one two", wordSpansMs: [[0, 1000]])
        : NativeTranscriber.Pass(text: "two three", wordSpansMs: [[Int.max, Int.max], [-1, 5], [9, 3]])
    })
    #expect(tailBad.speechMs == nil)
    // Absurd inline spans are dropped; the valid one still counts (short take, no tail).
    let inline = try NativeTranscriber(settings: settings).transcribeTimed(samples: [0.1], passes: { _, _ in
      NativeTranscriber.Pass(text: "x", wordSpansMs: [[Int.max, Int.max], [0, 400], [0, 10_000_000]])
    })
    #expect(inline.speechMs == 400)
    #expect(NativeTranscriber.offset([[Int.max - 1, Int.max]], by: 5) == nil)
  }

  @Test func noInlineTimingsIsUnknownEvenWithTailTimings() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      flow == "inline" ? NativeTranscriber.Pass(text: "one two")
        : NativeTranscriber.Pass(text: "two three", wordSpansMs: [[0, 500]])
    })
    #expect(result.speechMs == nil)
  }

  @Test func blankTailKeepsInlineSpeech() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let result = try NativeTranscriber(settings: settings).transcribeTimed(samples: samples, passes: { _, flow in
      flow == "inline" ? NativeTranscriber.Pass(text: "one two", wordSpansMs: [[0, 1000]])
        : NativeTranscriber.Pass(text: "  ")
    })
    #expect(result.speechMs == 1000)
  }
}
