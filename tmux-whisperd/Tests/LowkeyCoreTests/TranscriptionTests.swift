import Darwin
import Foundation
import Testing
@testable import LowkeyCore
import TmuxWhisperKit

struct AudioPrepTests {
  @Test func padsTheTailThenToOneSecond() {
    let pcm = [Int16](repeating: 7, count: 20_000)
    let padded = AudioPrep.padded(pcm, tailPadMs: 500)
    #expect(padded.count == 28_000)
    #expect(Array(padded.prefix(20_000)) == pcm)
    #expect(padded.suffix(8_000).allSatisfy { $0 == 0 })
    // New in 3b: sub-second takes reach FluidAudio's 1 s minimum.
    #expect(AudioPrep.padded([1, 2, 3], tailPadMs: 500).count == 16_000)
    #expect(AudioPrep.padded([1, 2, 3], tailPadMs: 0).count == 16_000)
    #expect(AudioPrep.padded(pcm, tailPadMs: 10).count == 20_160)
  }

  @Test func durationRoundsLikeFfprobeAndAwk() {
    // ffprobe prints 15.812500 for 253000 samples; awk "%.0f" rounds half to even.
    #expect(AudioPrep.ffprobeDurationMs(sampleCount: 253_000) == 15_812)
    #expect(AudioPrep.ffprobeDurationMs(sampleCount: 199_999) == 12_500)
    #expect(AudioPrep.ffprobeDurationMs(sampleCount: 248_008) == 15_500)
    #expect(AudioPrep.ffprobeDurationMs(sampleCount: 20_345) == 1_272)
  }

  @Test func tailRescueWindowFollowsTheCLI() {
    let settings = TranscriptionSettings(socketPath: "/s", modelPath: "/m")
    #expect(AudioPrep.tailRescueWindowMs(paddedSampleCount: 16 * 12_000, settings: settings) == 8_000)
    #expect(AudioPrep.tailRescueWindowMs(paddedSampleCount: 16 * 11_999, settings: settings) == nil)
    var off = settings
    off.tailRescue = false
    #expect(AudioPrep.tailRescueWindowMs(paddedSampleCount: 16 * 30_000, settings: off) == nil)
    var short = settings
    short.tailRescueMs = "200"   // raised to 1 s
    short.tailRescueMinMs = "1500"
    #expect(AudioPrep.tailRescueWindowMs(paddedSampleCount: 16 * 2_001, settings: short) == 1_000)
    #expect(AudioPrep.tailRescueWindowMs(paddedSampleCount: 16 * 2_000, settings: short) == nil)
    var wide = settings
    wide.tailRescueMs = "11500"  // duration must exceed window + 1 s
    #expect(AudioPrep.tailRescueWindowMs(paddedSampleCount: 16 * 12_500, settings: wide) == nil)
    #expect(AudioPrep.tail([1, 2, 3, 4], windowMs: 0).isEmpty)
    #expect(AudioPrep.tail(Array(repeating: 1, count: 40_000), windowMs: 1_000).count == 16_000)
  }
}

struct TranscriptionSettingsTests {
  @Test func parsesNumbersLikeBash() {
    #expect(TranscriptionSettings.bashInt("", default: 8000) == 8000)
    #expect(TranscriptionSettings.bashInt("abc", default: 8000) == 8000)
    #expect(TranscriptionSettings.bashInt("-5", default: 8000) == 8000)
    #expect(TranscriptionSettings.bashInt("0", default: 8000) == 0)
    #expect(TranscriptionSettings.bashInt("250", default: 8000) == 250)
    #expect(TranscriptionSettings.bashInt("010", default: 8000) == nil)  // octal in (( ))
    #expect(TranscriptionSettings.bashInt("99999999999999999999999", default: 1) == nil)
  }

  @Test func reportsWhyTheCLIIsNeeded() {
    let base = TranscriptionSettings(socketPath: "/s", modelPath: "/m")
    #expect(base.cliReason == nil)
    #expect(TranscriptionSettings(socketPath: "/s", modelPath: nil).cliReason != nil)
    var trimmed = base
    trimmed.silenceTrim = true
    #expect(trimmed.cliReason != nil)
    var octal = base
    octal.tailPadMs = "0500"
    #expect(octal.cliReason != nil)
    var keepLogs = base
    keepLogs.keepLogs = true
    #expect(keepLogs.cliReason == nil)  // inline record writes the debug archive
    var noFFmpeg = base
    noFFmpeg.ffmpeg = false
    #expect(noFFmpeg.cliReason != nil)
    var noPad = base
    noPad.tailPadMs = "0"
    #expect(noPad.cliReason == nil && noPad.tailPad == 0)
  }

  @Test func decodesTheAppConfigSections() throws {
    let json = #"""
    {"schema_version":1,"cli_version":"0.10.0-dev","hotkey":"ctrl+option+space","sounds":{},
     "inline":{"autosend":true,"send_mode":"enter","paste_target":"current","process_sound":true,"activate_delay_ms":90,"send_delay_ms":35},
     "cleanup":{"config_dir":"/c","clean":"0","repeats_level":"1","vocab_clean":"1","british_spelling":"1",
       "code_paragraph_min_words":"70","long_paragraph_min_words":"55","force_mode":null,"postprocess":false,
       "locale_ctype":"","locale_collate":""},
     "transcription":{"socket_path":"/s.sock","model_path":"/m","model_version":"v3","model_label":"m","language":"en",
       "tail_pad_ms":"500","tail_rescue":true,"tail_rescue_ms":"","tail_rescue_min_ms":"","chunking":false,
       "silence_trim":false,"keep_logs":false,"ffmpeg":true,"timeout_seconds":"600","processing_dir":"/p"},
     "pipeline":{"native":true,"verify":true}}
    """#
    var config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.nativePipelineBlocker == nil)
    #expect(config.transcription?.socketPath == "/s.sock")
    #expect(config.delivery.sendDelayMs == 35)

    let disabled = json.replacingOccurrences(of: #""native":true"#, with: #""native":false"#)
    config = try JSONDecoder().decode(AppConfig.self, from: Data(disabled.utf8))
    #expect(config.nativePipelineBlocker == "[app] native_pipeline = false")

    let llm = json.replacingOccurrences(of: #""postprocess":false"#, with: #""postprocess":true"#)
    config = try JSONDecoder().decode(AppConfig.self, from: Data(llm.utf8))
    #expect(config.nativePipelineBlocker == "LLM post-processing is on")
  }

  @Test func invalidConfigNeverSendsWithFallbackDefaults() throws {
    func config(_ status: String) throws -> AppConfig {
      let json = #"""
      {"schema_version":1,"cli_version":"0.10.0-dev","hotkey":"ctrl+option+space","sounds":{},
       "inline":{"autosend":true,"send_mode":"enter","paste_target":"current","process_sound":true,"activate_delay_ms":90,"send_delay_ms":35},
       "config":STATUS}
      """#.replacingOccurrences(of: "STATUS", with: status)
      return try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }
    let valid = try config(#"{"error":null,"source":"file"}"#)
    #expect(!valid.usingFallbackDefaults && valid.delivery.autosend)
    let lastGood = try config(#"{"error":"Invalid value (at line 3)","source":"last_good"}"#)
    #expect(!lastGood.usingFallbackDefaults && lastGood.delivery.autosend)
    let defaults = try config(#"{"error":"Invalid value (at line 3)","source":"defaults"}"#)
    #expect(defaults.usingFallbackDefaults)
    #expect(defaults.delivery.autosend == false)
    #expect(defaults.delivery.sendMode == "enter" && defaults.delivery.sendDelayMs == 35)
  }

  @Test func olderCLIsKeepTheCLIPath() throws {
    let json = #"""
    {"schema_version":1,"cli_version":"0.9.0","hotkey":"ctrl+option+space","sounds":{},
     "inline":{"autosend":true,"send_mode":"enter","paste_target":"current","process_sound":true,"activate_delay_ms":90,"send_delay_ms":35}}
    """#
    let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(config.nativePipelineBlocker != nil)
  }
}

/// Records what the fake daemon was asked to transcribe.
private final class CallLog: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [(flow: String, samples: [Int16])] = []

  func add(flow: String, samples: [Int16]) { lock.withLock { calls.append((flow, samples)) } }
  var all: [(flow: String, samples: [Int16])] { lock.withLock { calls } }
}

private func readPCM(_ url: URL) throws -> [Int16] {
  let data = try Data(contentsOf: url)
  return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

struct NativeTranscriberTests {
  private let settings = TranscriptionSettings(socketPath: "/s", modelPath: "/m")

  @Test func shortTakeIsPaddedAndTranscribedOnce() throws {
    let log = CallLog()
    let samples = [Float](repeating: 0.25, count: 32_000)
    let result = try NativeTranscriber(settings: settings).transcribe(samples: samples) { wav, flow in
      log.add(flow: flow, samples: try readPCM(wav))
      return "hello world\n\n"
    }
    #expect(result.transcript == "hello world")
    #expect(result.tailRescueMs == nil)
    #expect(log.all.map(\.flow) == ["inline"])
    #expect(log.all[0].samples.count == 40_000)
    #expect(log.all[0].samples.prefix(32_000).allSatisfy { $0 == 8192 })
    #expect(result.captureSamples == 32_000)
  }

  @Test func longTakeRescuesTheTail() throws {
    let log = CallLog()
    let samples = (0..<(16_000 * 13)).map { Float($0 % 100) / 100 }
    let result = try NativeTranscriber(settings: settings).transcribe(samples: samples) { wav, flow in
      log.add(flow: flow, samples: try readPCM(wav))
      return flow == "inline" ? "so the plan is to ship it" : "ship it today\nand test"
    }
    let calls = log.all
    #expect(calls.map(\.flow) == ["inline", "inline-tail"])
    #expect(calls[1].samples.count == 128_000)
    #expect(Array(calls[1].samples) == Array(calls[0].samples.suffix(128_000)))
    #expect(result.tailRescueMs == 8_000)
    #expect(result.transcript == "so the plan is to ship it today and test")
  }

  @Test func failedOrBlankTailKeepsTheFullTranscript() throws {
    let samples = [Float](repeating: 0, count: 16_000 * 13)
    let failing = try NativeTranscriber(settings: settings).transcribe(samples: samples) { _, flow in
      if flow == "inline-tail" { throw DaemonClient.ClientError.daemon(code: "x", message: "y") }
      return "full text"
    }
    #expect(failing.transcript == "full text" && failing.tailRescueFailed)
    let blank = try NativeTranscriber(settings: settings).transcribe(samples: samples) { _, flow in
      flow == "inline" ? "full text" : " \n "
    }
    #expect(blank.transcript == "full text" && !blank.tailRescueFailed)
  }

  @Test func keepsThePaddedWAVOnlyWhenAsked() throws {
    let kept = try NativeTranscriber(settings: settings, keepWAV: true).transcribe(samples: [0.1]) { _, _ in "x" }
    let url = try #require(kept.keptWAV)
    #expect(try readPCM(url).count == 16_000)
    try FileManager.default.removeItem(at: url)
    let dropped = try NativeTranscriber(settings: settings).transcribe(samples: [0.1]) { _, _ in "x" }
    #expect(dropped.keptWAV == nil)
  }

  @Test func fullTranscriptionErrorsPropagateWithTheKeptWAV() throws {
    do {
      _ = try NativeTranscriber(settings: settings).transcribe(samples: [0]) { _, _ in
        throw DaemonClient.ClientError.unreachable("x")
      }
      Issue.record("expected a failure")
    } catch let failure as NativeTranscriber.Failure {
      #expect(failure.underlying as? DaemonClient.ClientError == .unreachable("x"))
      #expect(failure.keptWAV == nil)
    }
    do {
      _ = try NativeTranscriber(settings: settings, keepWAV: true).transcribe(samples: [0]) { _, _ in
        throw DaemonClient.ClientError.timedOut(1)
      }
      Issue.record("expected a failure")
    } catch let failure as NativeTranscriber.Failure {
      let url = try #require(failure.keptWAV)
      #expect(FileManager.default.fileExists(atPath: url.path))
      try FileManager.default.removeItem(at: url)
    }
  }
}

/// Answers like tmux-whisperd without a model, recording requests.
private actor FakeDaemon: DaemonRequestHandling {
  var requests: [DaemonRequest] = []
  let delay: Duration

  init(delay: Duration = .zero) { self.delay = delay }

  func handle(_ request: DaemonRequest) async -> DaemonResponse {
    requests.append(request)
    switch request.op {
    case .ping:
      return DaemonResponse(id: request.id, ok: true, message: "ok", version: DaemonInfo.daemonVersion)
    case .transcribe:
      try? await Task.sleep(for: delay)
      if request.flow == "fail" {
        return .failure(id: request.id, code: "model_path_invalid", message: "bad model")
      }
      return DaemonResponse(id: request.id, ok: true, text: "café \u{1F600} transcript")
    case .warmup:
      return DaemonResponse(id: request.id, ok: true)
    }
  }
}

/// Runs blocking client code on a GCD thread, as the app does. Blocking a
/// Swift concurrency thread instead can starve the in-process server's
/// handler on small CI runners.
private func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(with: Result { try body() })
    }
  }
}

struct DaemonClientTests {
  private func socketPath() -> String {
    NSTemporaryDirectory() + "lk-\(UUID().uuidString.prefix(8)).sock"
  }

  @Test func talksToTheRealServer() async throws {
    let path = socketPath()
    let daemon = FakeDaemon()
    let server = UnixSocketServer(socketPath: path, handler: daemon)
    try server.start()
    defer { server.stop() }

    let client = DaemonClient(socketPath: path)
    #expect(try await offPool { client.ping(timeout: 5) } == DaemonInfo.daemonVersion)
    let text = try await offPool {
      try client.transcribe(
        wav: URL(fileURLWithPath: "/tmp/take.wav"), language: "en", flow: "inline",
        modelPath: "/models/parakeet", modelVersion: "v3", timeout: 5)
    }
    #expect(Array(text.utf8) == Array("café \u{1F600} transcript".utf8))

    let request = try #require(await daemon.requests.last)
    #expect(request.op == .transcribe)
    #expect(request.wavPath == "/tmp/take.wav")
    #expect(request.flow == "inline")
    #expect(request.language == "en")
    #expect(request.modelPath == "/models/parakeet")
    #expect(request.modelVersion == "v3")

    await #expect(throws: DaemonClient.ClientError.daemon(code: "model_path_invalid", message: "bad model")) {
      _ = try await offPool {
        try client.transcribe(wav: URL(fileURLWithPath: "/tmp/x.wav"), language: "en", flow: "fail",
                              modelPath: "/m", modelVersion: nil, timeout: 5)
      }
    }
  }

  /// Fast replies (errors, pings) can arrive and close before the client
  /// shortens its receive timeout; that must not look like a protocol error.
  @Test func fastRepliesAreNeverProtocolErrors() async throws {
    let path = socketPath()
    let server = UnixSocketServer(socketPath: path, handler: FakeDaemon())
    try server.start()
    defer { server.stop() }
    let client = DaemonClient(socketPath: path)
    let outcomes = try await offPool { () -> [String] in
      (0..<200).map { _ in
        do {
          _ = try client.transcribe(wav: URL(fileURLWithPath: "/tmp/x.wav"), language: "en", flow: "fail",
                                    modelPath: "/m", modelVersion: nil, timeout: 5)
          return "ok"
        } catch DaemonClient.ClientError.daemon {
          return "daemon"
        } catch {
          return "\(error)"
        }
      }
    }
    #expect(outcomes.allSatisfy { $0 == "daemon" }, "\(Set(outcomes))")
    #expect(try await offPool { (0..<200).allSatisfy { _ in client.ping(timeout: 5) != nil } })
  }

  @Test func reportsAnUnreachableDaemonAfterOneRetry() {
    var client = DaemonClient(socketPath: socketPath())
    client.retryDelay = 0.01
    #expect(client.ping(timeout: 0.5) == nil)
    #expect {
      _ = try client.transcribe(wav: URL(fileURLWithPath: "/tmp/x.wav"), language: "en", flow: "inline",
                                modelPath: "/m", modelVersion: nil, timeout: 1)
    } throws: { error in
      if case DaemonClient.ClientError.unreachable = error { return true }
      return false
    }
  }

  @Test func timesOutOnASlowDaemon() async throws {
    let path = socketPath()
    let server = UnixSocketServer(socketPath: path, handler: FakeDaemon(delay: .seconds(3)))
    try server.start()
    defer { server.stop() }
    let started = Date()
    await #expect(throws: DaemonClient.ClientError.timedOut(0.3)) {
      _ = try await offPool {
        try DaemonClient(socketPath: path).transcribe(
          wav: URL(fileURLWithPath: "/tmp/x.wav"), language: "en", flow: "inline", modelPath: "/m",
          modelVersion: nil, timeout: 0.3)
      }
    }
    #expect(Date().timeIntervalSince(started) < 2)
  }
}

struct PendingRecordsTests {
  @Test func spoolsReplaysAndDropsStaleRecords() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "lk-pending-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let pending = PendingRecords(directory: dir)
    let now = Date()
    var first = TakeRecord(takeId: "a", status: "ok", delivered: true)
    first.text = "hello"
    let firstURL = try pending.save(first, at: now.addingTimeInterval(-60))
    try pending.save(TakeRecord(takeId: "b", status: "no_speech", delivered: false), at: now)
    try pending.save(TakeRecord(takeId: "old", status: "ok", delivered: true), at: now.addingTimeInterval(-8 * 24 * 3600))
    try Data("junk".utf8).write(to: dir.appendingPathComponent("9999999999999-bad.json"))

    let attrs = try FileManager.default.attributesOfItem(atPath: firstURL.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)

    let (records, dropped) = pending.leftovers(now: now)
    #expect(records.map(\.record.takeId) == ["a", "b"])
    #expect(records[0].record == first)
    #expect(dropped.count == 2)
    pending.remove(records[0].url)
    #expect(pending.leftovers(now: now).records.map(\.record.takeId) == ["b"])
  }
}

struct RecoveredTakesTests {
  @Test func savesListsAndReloadsTakes() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "lk-recovered-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecoveredTakes(directory: dir)
    let samples: [Float] = [0, 0.5, -0.5, 0.25]
    let now = Date()
    let second = try store.save(samples: samples, takeId: "b-2", at: now)
    let first = try store.save(samples: [0.1], takeId: "a-1", at: now.addingTimeInterval(-5))
    #expect(store.all() == [first, second])
    #expect(RecoveredTakes.takeId(of: second) == "b-2")
    let attrs = try FileManager.default.attributesOfItem(atPath: second.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    // Round-trips through the same 16-bit quantization the pipeline uses.
    #expect(WAVEncoder.pcm16(try RecoveredTakes.samples(at: second)) == WAVEncoder.pcm16(samples))
    store.remove(first)
    #expect(store.all() == [second])
  }
}

struct TakeRecordTests {
  @Test func encodesTheInlineRecordPayload() throws {
    var record = TakeRecord(takeId: "t1", status: "ok", delivered: true)
    record.rawText = "open ai"
    record.text = "OpenAI"
    record.mode = "code"
    record.recordMs = 3000
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    #expect(object["take_id"] as? String == "t1")
    #expect(object["raw_text"] as? String == "open ai")
    #expect(object["record_ms"] as? Int == 3000)
    #expect(object["delivered"] as? Bool == true)
    #expect(object["startup_source"] as? String == "app:native")
  }

  @Test func takeMarkerLooksLikeTheCLIsAndFollowsTheTake() throws {
    let dir = NSTemporaryDirectory() + "lk-markers-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let marker = try #require(TakeMarker.create(directory: dir, takeId: "abc-123/../x", phase: .recording, pid: 4242))
    #expect(marker.url.lastPathComponent == "inline-lowkey-abc-123x")
    var body = try String(contentsOf: marker.url, encoding: .utf8)
    #expect(body.hasPrefix("pid=4242\nkind=inline\nsession_id=abc-123x\nphase=recording\n"))
    for phase in [TakeMarker.Phase.queued, .processing, .cli] {
      marker.update(phase)
      body = try String(contentsOf: marker.url, encoding: .utf8)
      #expect(body.contains("\nphase=\(phase.rawValue)\n"))
      #expect(body.hasPrefix("pid=4242\n"))
    }
    // Renamed into place: no temp files left where the CLI's glob would see them.
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["inline-lowkey-abc-123x"])
    marker.remove()
    #expect(!FileManager.default.fileExists(atPath: marker.url.path))
    // A late update never brings a finished take back.
    marker.update(.processing)
    #expect(!FileManager.default.fileExists(atPath: marker.url.path))
  }

  @Test func staleTakeMarkersAreRemovedAtLaunch() throws {
    let dir = NSTemporaryDirectory() + "lk-markers-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    _ = try #require(TakeMarker.create(directory: dir, takeId: "dead", phase: .processing, pid: 111))
    _ = try #require(TakeMarker.create(directory: dir, takeId: "other-app", phase: .recording, pid: 222))
    _ = try #require(TakeMarker.create(directory: dir, takeId: "reused-pid", phase: .queued, pid: 333))
    _ = try #require(TakeMarker.create(directory: dir, takeId: "mine", phase: .recording, pid: 444))
    try "pid=555\nkind=inline\n".write(toFile: dir + "/inline-12345", atomically: true, encoding: .utf8)
    // 222 is another running Lowkey; 333 was reused by some other program.
    let removed = TakeMarker.removeStale(directory: dir, ownPid: 444, isLowkey: { $0 == 222 })
    #expect(Set(removed) == ["inline-lowkey-dead", "inline-lowkey-reused-pid"])
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir))
            == ["inline-lowkey-other-app", "inline-lowkey-mine", "inline-12345"])
    #expect(TakeMarker.isRunningLowkey(getpid()) == false)
  }
}
