import Foundation
import Testing
@testable import KhulumaCore

/// Records what the client sent; answers with a canned status and body.
final class FakeScribeTransport: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [(request: URLRequest, body: Data)] = []
  var status: Int? = 200
  var body = Data(#"{"text":"hello there"}"#.utf8)
  var error: Error?

  var transport: ScribeClient.Transport {
    { [self] request, body in
      lock.lock(); requests.append((request, body)); lock.unlock()
      if let error { throw error }
      return (status, self.body)
    }
  }
}

private let fakeKey = "fake-test-key-123"

private func makeClient(_ fake: FakeScribeTransport, key: String? = fakeKey) -> ScribeClient {
  ScribeClient(credential: ScribeCredential(keychain: MemoryKeychain(key), environment: [:],
                                            home: URL(fileURLWithPath: "/nonexistent")),
               transport: fake.transport)
}

private func tempWAV() throws -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scribe-\(UUID().uuidString).wav")
  try WAVEncoder.encode(samples: [Float](repeating: 0.1, count: 1600)).write(to: url)
  return url
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

struct ScribeClientTests {
  @Test func sendsTheRequestTheCLIDid() throws {
    let fake = FakeScribeTransport()
    let wav = try tempWAV()
    defer { try? FileManager.default.removeItem(at: wav) }
    let transcript = try makeClient(fake).transcribe(wav: wav, language: "en")
    #expect(transcript == "hello there")
    let sent = try #require(fake.requests.first)
    #expect(sent.request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    #expect(sent.request.httpMethod == "POST")
    #expect(sent.request.value(forHTTPHeaderField: "xi-api-key") == fakeKey)
    #expect(sent.request.timeoutInterval == 110)
    let contentType = try #require(sent.request.value(forHTTPHeaderField: "Content-Type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    let body = text(sent.body)
    #expect(body.contains(#"name="model_id"\#r\#n\#r\#nscribe_v2"#))
    #expect(body.contains(#"name="tag_audio_events"\#r\#n\#r\#nfalse"#))
    #expect(body.contains(#"name="language_code"\#r\#n\#r\#nen"#))
    #expect(body.contains(#"name="file"; filename=""# + wav.lastPathComponent + "\""))
    #expect(sent.body.range(of: Data("RIFF".utf8)) != nil)
    // The key never rides in the body.
    #expect(!body.contains(fakeKey))
  }

  @Test func autoOrEmptyLanguageSendsNone() throws {
    let wav = try tempWAV()
    defer { try? FileManager.default.removeItem(at: wav) }
    for language in ["auto", ""] {
      let fake = FakeScribeTransport()
      _ = try makeClient(fake).transcribe(wav: wav, language: language)
      #expect(!text(try #require(fake.requests.first).body).contains("language_code"))
    }
  }

  @Test func finderCloudUploadsOriginalMediaAndKeepsSoundLabels() throws {
    let source = try tempWAV()
    defer { try? FileManager.default.removeItem(at: source) }
    let media = try Data(contentsOf: source)
    let output = source.deletingPathExtension().appendingPathExtension("txt")
    defer { try? FileManager.default.removeItem(at: output) }
    let fake = FakeScribeTransport()
    fake.body = Data(#"{"text":"Good point. (laughter)"}"#.utf8)
    let client = ScribeClient(credential: ScribeCredential(keychain: MemoryKeychain(fakeKey), environment: [:]),
                              transport: { _, _ in throw URLError(.unsupportedURL) },
                              fileTransport: { request, staged in try fake.transport(request, Data(contentsOf: staged)) })
    let outcome = QuickActionRun.run([source.path], workDirectory: { try FileTranscribeCommand.privateWorkDirectory() }) {
      try client.transcribeFile($0, workDirectory: $1)
    }
    #expect(outcome.failures.isEmpty)
    #expect(outcome.combined == "Good point. (laughter)")
    #expect(try String(contentsOf: output, encoding: .utf8) == "Good point. (laughter)\n")
    let request = try #require(fake.requests.first)
    #expect(fake.requests.count == 1)
    #expect(request.body.range(of: media) != nil)
    #expect(request.request.timeoutInterval == ScribeClient.fileTimeout)
    let form = text(request.body)
    #expect(form.contains(#"name="tag_audio_events"\#r\#n\#r\#ntrue"#))
    #expect(!form.contains("language_code"))
    #expect(!form.contains(source.lastPathComponent))
  }

  @Test func eachFailureHasTheCLIWording() throws {
    let wav = try tempWAV()
    defer { try? FileManager.default.removeItem(at: wav) }
    func failure(_ configure: (FakeScribeTransport) -> Void, key: String? = fakeKey, file: URL? = nil) -> String? {
      let fake = FakeScribeTransport()
      configure(fake)
      do { _ = try makeClient(fake, key: key).transcribe(wav: file ?? wav, language: "en"); return nil } catch {
        return error.localizedDescription
      }
    }
    #expect(failure({ _ in }, key: nil)?.hasPrefix("ElevenLabs API key unavailable.") == true)
    #expect(failure({ _ in }, file: URL(fileURLWithPath: "/nonexistent/x.wav")) == "ElevenLabs audio file is unavailable.")
    #expect(failure({ $0.error = URLError(.timedOut) })
      == "ElevenLabs request could not complete. Check your connection and retry.")
    #expect(failure({ $0.status = nil }) == "ElevenLabs returned an unreadable response.")
    #expect(failure({ $0.status = 401 })
      == "ElevenLabs authentication failed (HTTP 401). Check your API key and speech-to-text access.")
    #expect(failure({ $0.status = 403 })
      == "ElevenLabs authentication failed (HTTP 403). Check your API key and speech-to-text access.")
    #expect(failure({ $0.status = 429 })
      == "ElevenLabs request limit reached (HTTP 429). Check account limits and retry later.")
    #expect(failure({ $0.status = 500 })
      == "ElevenLabs transcription failed (HTTP 500). The recording is kept when recovery is available.")
    #expect(failure({ $0.status = 201 })
      == "ElevenLabs transcription failed (HTTP 201). The recording is kept when recovery is available.")
    for body in ["not json", #"{"text": 5}"#, #"{"other": "x"}"#, #"["text"]"#] {
      #expect(failure({ $0.body = Data(body.utf8) }) == "ElevenLabs returned an unreadable transcript.", "\(body)")
    }
  }

  @Test func neitherKeyNorResponseBodyReachesAnError() throws {
    let wav = try tempWAV()
    defer { try? FileManager.default.removeItem(at: wav) }
    let fake = FakeScribeTransport()
    fake.status = 401
    fake.body = Data(#"{"detail":"bad key fake-test-key-123, transcript: secret words"}"#.utf8)
    do { _ = try makeClient(fake).transcribe(wav: wav, language: "en") } catch {
      let message = "\(error) \(error.localizedDescription) \(String(reflecting: error))"
      #expect(!message.contains(fakeKey))
      #expect(!message.contains("secret words"))
    }
    fake.error = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "leak fake-test-key-123"])
    do { _ = try makeClient(fake).transcribe(wav: wav, language: "en") } catch {
      #expect(!"\(error) \(error.localizedDescription)".contains(fakeKey))
    }
  }

  @Test func missingKeyStopsBeforeAnyRequest() throws {
    let fake = FakeScribeTransport()
    let wav = try tempWAV()
    defer { try? FileManager.default.removeItem(at: wav) }
    #expect(throws: ScribeClient.Failure.noKey) { try makeClient(fake, key: nil).transcribe(wav: wav, language: "en") }
    #expect(fake.requests.isEmpty)
  }
}

struct ScribeRouteTests {
  private func route(_ fake: FakeScribeTransport, key: String? = fakeKey, keepWAV: Bool = false,
                     directory: URL) -> ScribeRoute {
    ScribeRoute(client: makeClient(fake, key: key),
                cleanup: CleanupSettings(configDir: directory.path, clean: "0"),
                language: "en", keepWAV: keepWAV, directory: directory)
  }

  private func scratch() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("route-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private let samples = [Float](repeating: 0.1, count: 16_000)

  @Test func successGivesTextAndARecord() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fake = FakeScribeTransport()
    fake.body = Data(#"{"text":"Hello there.\n"}"#.utf8)
    let outcome = route(fake, directory: dir).run(samples: samples, takeId: "t1", app: "Notes", recordMs: 1000,
                                                  startupMs: 12, startedAtMs: 99)
    guard case .text(let text, let record) = outcome else { Issue.record("\(outcome)"); return }
    #expect(text == "Hello there.")
    #expect(record.takeId == "t1" && record.status == "ok" && record.delivered == false)
    #expect(record.model == "scribe_v2" && record.app == "Notes" && record.text == text)
    #expect(record.recordMs == 1000 && record.startupMs == 12 && record.startedAtMs == 99)
    #expect(record.captureWavBytes == 44 + 2 * 16_000)
    #expect(record.wavPath == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    #expect(fake.requests.count == 1)
  }

  @Test func recoveredTakesKeepTheirStatus() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    guard case .text(_, let record) = route(FakeScribeTransport(), directory: dir)
      .run(samples: samples, takeId: "t2", status: "recovered", app: nil, recordMs: 1, startupMs: 0, startedAtMs: nil)
    else { Issue.record("no text"); return }
    #expect(record.status == "recovered")
  }

  @Test func dictationPassesTheSoundLabelPreferenceAndPreservesLabels() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(folder: dir)
    let env = SettingsEnvironment(appFolder: dir, home: dir.path, soundsDir: "/s", modelsDir: "/m",
                                  defaultSocketPath: "/sock", ffmpegAvailable: false, keyAvailable: true)
    #expect(store.load().settings.transcription.scribeTagAudioEvents)
    for enabled in [true, false] {
      try store.set("transcription.scribe_tag_audio_events", value: String(enabled))
      let config = AppConfig(settings: store.load().settings, environment: env)
      #expect(config.transcription.scribeTagAudioEvents == enabled)
      let fake = FakeScribeTransport()
      let expected = enabled ? "Good point. (laughter)" : "Good point."
      fake.body = try JSONEncoder().encode(["text": expected])
      let route = ScribeRoute(client: makeClient(fake), cleanup: config.cleanup, language: "en",
                             tagAudioEvents: config.transcription.scribeTagAudioEvents, directory: dir)
      guard case .text(let result, _) = route.run(samples: samples, takeId: "label", app: nil,
                                                  recordMs: 1000, startupMs: 0, startedAtMs: nil) else {
        Issue.record("Expected a transcript")
        return
      }
      #expect(result == expected)
      let form = text(try #require(fake.requests.first).body)
      #expect(form.contains(#"name="tag_audio_events"\#r\#n\#r\#n\#(enabled)"#))
    }
  }

  @Test func failureKeepsTheTakeAndMakesNoRecord() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fake = FakeScribeTransport()
    fake.status = 429
    let outcome = route(fake, directory: dir).run(samples: samples, takeId: "t3", app: nil, recordMs: 1, startupMs: 0, startedAtMs: nil)
    #expect(outcome == .failed("ElevenLabs request limit reached (HTTP 429). Check account limits and retry later."))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

    let noKey = route(FakeScribeTransport(), key: nil, directory: dir)
      .run(samples: samples, takeId: "t4", app: nil, recordMs: 1, startupMs: 0, startedAtMs: nil)
    guard case .failed(let message) = noKey else { Issue.record("\(noKey)"); return }
    #expect(message.hasPrefix("ElevenLabs API key unavailable."))
  }

  @Test func emptyTranscriptIsNoSpeech() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fake = FakeScribeTransport()
    fake.body = Data(#"{"text":"   "}"#.utf8)
    guard case .noSpeech(let record) = route(fake, directory: dir)
      .run(samples: samples, takeId: "t5", app: nil, recordMs: 1, startupMs: 0, startedAtMs: nil)
    else { Issue.record("not no-speech"); return }
    #expect(record.status == "no_speech" && record.delivered == false && record.text.isEmpty)
  }

  @Test func debugLoggingKeepsTheWAVForTheRecorder() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    guard case .text(_, let record) = route(FakeScribeTransport(), keepWAV: true, directory: dir)
      .run(samples: samples, takeId: "t6", app: nil, recordMs: 1, startupMs: 0, startedAtMs: nil)
    else { Issue.record("no text"); return }
    let kept = try #require(record.wavPath)
    #expect(FileManager.default.fileExists(atPath: kept))
  }
}

struct ScribeConfigTests {
  @Test func scribeSettingsRouteNativelyWithoutAModel() throws {
    let env = SettingsEnvironment(appFolder: URL(fileURLWithPath: "/tmp/a"), home: "/tmp/h", soundsDir: "/s", modelsDir: "/m",
                                  defaultSocketPath: "/sock", ffmpegAvailable: false, keyAvailable: true)
    var settings = AppSettings()
    settings.transcription.provider = "elevenlabs"
    let config = AppConfig(settings: settings, environment: env)
    #expect(config.scribe != nil && config.native == nil && config.nativePipelineBlocker == nil)
    #expect(config.transcription.modelLabel == "scribe_v2" && config.transcription.keyAvailable)
    settings.transcription.provider = "parakeet"
    #expect(AppConfig(settings: settings, environment: env).scribe == nil)
  }
}

struct ScribeRecoveryTests {
  @Test func everyUnsettledEndingKeepsItsAudio() {
    #expect(TakeResult.delivered(recorded: false).keepsAudio)
    #expect(!TakeResult.delivered(recorded: true).keepsAudio)
    #expect(TakeResult.failed("x").keepsAudio)
    #expect(TakeResult.pasteFailed("x", recorded: false).keepsAudio)
    #expect(!TakeResult.pasteFailed("x", recorded: true).keepsAudio)
    #expect(TakeResult.timedOut("x", kept: false).keepsAudio)
    #expect(!TakeResult.timedOut("x", kept: true).keepsAudio)
    #expect(!TakeResult.noSpeech.keepsAudio)
  }

  @Test func recoveredTakeAlreadyRecordedIsRecognised() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = TakeRecorder(root: root.appendingPathComponent("support"), settings: .init(keepLogs: false),
                                temporaryRoots: [root.appendingPathComponent("tmp")])
    let pending = PendingRecords(directory: root.appendingPathComponent("pending", isDirectory: true))
    #expect(!recorder.isRecorded(takeId: "abc", pending: pending))
    // Spooled but not yet written to history (a crash between the two).
    var record = TakeRecord(takeId: "abc", status: "ok", delivered: true)
    record.text = "hello"
    _ = try pending.save(record)
    #expect(recorder.isRecorded(takeId: "abc", pending: pending))
    #expect(!recorder.isRecorded(takeId: "other", pending: pending))
    // A failed transcription saved no text: its audio must still be recovered.
    _ = try pending.save(TakeRecord(takeId: "failed1", status: "transcribe_failed", delivered: false))
    #expect(!recorder.isRecorded(takeId: "failed1", pending: pending))
    _ = try pending.save(TakeRecord(takeId: "quiet1", status: "no_speech", delivered: false))
    #expect(recorder.isRecorded(takeId: "quiet1", pending: pending))
    // Written to history and the spool cleared.
    for url in pending.leftovers().records.map(\.url) { pending.remove(url) }
    #expect(!recorder.isRecorded(takeId: "quiet1", pending: pending))
    #expect(!recorder.isRecorded(takeId: "abc", pending: pending))
    _ = recorder.apply(PendingTake(record: record), spooled: nil, pending: pending)
    #expect(recorder.isRecorded(takeId: "abc", pending: pending))
  }

  @Test func recoveredFileNameCarriesTheInFlightIdUsedAsTakeId() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rf-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecoveredTakes(directory: dir)
    let flight = InFlightTakes(store: store)
    let id = flight.add(samples: [0.1, 0.2])
    let url = try flight.keep(id)
    #expect(RecoveredTakes.takeId(of: url) == id)
  }
}
