import Foundation
import Testing
@testable import KhulumaDaemonKit
import FluidAudio

struct ProtocolTests {
  @Test func decodesCLIRequestWithSnakeCaseKeys() throws {
    let json = #"{"id":"abc","op":"transcribe","wav_path":"/tmp/a.wav","language":"en","flow":"inline","model_path":"/m","model_version":"v3"}"#
    let request = try JSONDecoder().decode(DaemonRequest.self, from: Data(json.utf8))
    #expect(request.id == "abc")
    #expect(request.op == .transcribe)
    #expect(request.wavPath == "/tmp/a.wav")
    #expect(request.modelPath == "/m")
    #expect(request.modelVersion == "v3")
  }

  @Test func rejectsUnknownOperation() {
    let json = #"{"id":"abc","op":"transcribe_file"}"#
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(DaemonRequest.self, from: Data(json.utf8))
    }
  }

  @Test func encodesResponseWithSnakeCaseKeysAndOmitsNils() throws {
    let response = DaemonResponse(id: "x", ok: true, text: "hi", durationMs: 7)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
    )
    #expect(object["duration_ms"] as? Int == 7)
    #expect(object["engine"] as? String == "swift_parakeet")
    #expect(object["text"] as? String == "hi")
    #expect(object["error_code"] == nil)
    #expect(object["version"] == nil)
    #expect(object["active_requests"] == nil)
  }

  @Test func failureCarriesCodeAndMessage() throws {
    let response = DaemonResponse.failure(id: "x", code: "protocol_error", message: "bad")
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
    )
    #expect(object["ok"] as? Bool == false)
    #expect(object["error_code"] as? String == "protocol_error")
    #expect(object["message"] as? String == "bad")
  }

  @Test func pingReportsVersionAndIdleState() async {
    let service = TranscriptionService()
    let response = await service.handle(DaemonRequest(id: "p", op: .ping))
    #expect(response.ok)
    #expect(response.version == DaemonInfo.daemonVersion)
    #expect(response.activeRequests == 0)
    #expect(response.pid == Int(getpid()))
    // Nothing loaded yet: the field is absent, not a stale value.
    #expect(response.modelLoaded == nil)
    let again = await service.handle(DaemonRequest(id: "q", op: .ping))
    #expect(response.generation?.isEmpty == false)
    #expect(again.generation == response.generation)
    #expect(await TranscriptionService().handle(DaemonRequest(id: "r", op: .ping)).generation != response.generation)
  }

  @Test func pingFieldsUseSnakeCaseAndStayOptional() throws {
    let response = DaemonResponse(
      id: "p", ok: true, pid: 42, generation: "g", modelLoaded: .init(path: "/m/", version: "v3"))
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
    )
    #expect(object["pid"] as? Int == 42)
    #expect(object["generation"] as? String == "g")
    let loaded = try #require(object["model_loaded"] as? [String: Any])
    #expect(loaded["path"] as? String == "/m/")
    #expect(loaded["version"] as? String == "v3")
    // Responses from older daemons (no new fields) still decode.
    let old = try JSONDecoder().decode(DaemonResponse.self, from: Data(#"{"id":"p","ok":true,"version":"0.2.0"}"#.utf8))
    #expect(old.pid == nil && old.generation == nil && old.modelLoaded == nil)
  }

  @Test func transcribeValidatesPathsBeforeLoadingModel() async {
    let service = TranscriptionService()
    let missingWav = await service.handle(DaemonRequest(id: "t", op: .transcribe))
    #expect(missingWav.errorCode == "wav_path_missing")

    let badWav = await service.handle(DaemonRequest(id: "t", op: .transcribe, wavPath: "/nonexistent/a.wav"))
    #expect(badWav.errorCode == "wav_path_invalid")
  }

  @Test func modelVersionParsing() throws {
    #expect(throws: DaemonServiceError.self) { try ASREngine.parseModelVersion("v9") }
    _ = try ASREngine.parseModelVersion("V3")
  }
}

struct SerialGateTests {
  actor Tracker {
    var inside = 0
    var maxInside = 0
    func enter() { inside += 1; maxInside = max(maxInside, inside) }
    func leave() { inside -= 1 }
  }

  @Test func neverRunsTwoSectionsAtOnce() async {
    let gate = SerialGate()
    let tracker = Tracker()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          await gate.withExclusiveAccess {
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(20))
            await tracker.leave()
          }
        }
      }
    }
    #expect(await tracker.maxInside == 1)
  }

  @Test func releasesAfterThrowing() async throws {
    struct Boom: Error {}
    let gate = SerialGate()
    await #expect(throws: Boom.self) {
      try await gate.withExclusiveAccess { throw Boom() }
    }
    let value = await gate.withExclusiveAccess { 42 }
    #expect(value == 42)
  }
}

struct WordSpansProtocolTests {
  @Test func omitsWordSpansWhenNilAndRoundTripsThem() throws {
    let plain = String(decoding: try JSONEncoder().encode(DaemonResponse(id: "a", ok: true, text: "hi")), as: UTF8.self)
    #expect(!plain.contains("word_spans_ms"))
    let spans = DaemonResponse(id: "a", ok: true, text: "hi there", wordSpansMs: [[80, 400], [420, 900]])
    let data = try JSONEncoder().encode(spans)
    #expect(String(decoding: data, as: UTF8.self).contains(#""word_spans_ms":[[80,400],[420,900]]"#))
    #expect(try JSONDecoder().decode(DaemonResponse.self, from: data) == spans)
  }

  @Test func wordSpansComeFromTokenTimings() {
    let tokens = [
      TokenTiming(token: "▁hel", tokenId: 1, startTime: 0.08, endTime: 0.2, confidence: 1),
      TokenTiming(token: "lo", tokenId: 2, startTime: 0.2, endTime: 0.4, confidence: 1),
      TokenTiming(token: "▁there", tokenId: 3, startTime: 2.0, endTime: 2.5004, confidence: 1),
    ]
    #expect(ASREngine.wordSpansMs(tokens) == [[80, 400], [2000, 2240]])
  }

  @Test func aTokenEndingAtTheNextStartIsCapped() {
    let tokens = [
      TokenTiming(token: "▁test", tokenId: 1, startTime: 1.84, endTime: 6.08, confidence: 1),
      TokenTiming(token: "▁and", tokenId: 2, startTime: 6.08, endTime: 6.4, confidence: 1),
    ]
    #expect(ASREngine.wordSpansMs(tokens) == [[1840, 2080], [6080, 6320]])
  }

  @Test func lateFullStopDoesNotSpanThePause() {
    // FluidAudio without durations: the end is the next token's start.
    let tokens = [
      TokenTiming(token: "▁test", tokenId: 1, startTime: 1.84, endTime: 2.0, confidence: 1),
      TokenTiming(token: ".", tokenId: 9, startTime: 5.76, endTime: 6.08, confidence: 1),
      TokenTiming(token: "▁and", tokenId: 2, startTime: 6.08, endTime: 6.4, confidence: 1),
    ]
    #expect(ASREngine.wordSpansMs(tokens) == [[1840, 2000], [6080, 6320]])
  }
}

struct WordGroupingTests {
  @Test func aBareBoundaryTokenSplitsWordsAcrossAPause() {
    let tokens = [
      TokenTiming(token: " hello", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 1),
      TokenTiming(token: " ", tokenId: 2, startTime: 6, endTime: 6.08, confidence: 1),
      TokenTiming(token: "world", tokenId: 3, startTime: 6.08, endTime: 6.32, confidence: 1),
    ]
    #expect(ASREngine.wordSpansMs(tokens) == [[0, 200], [6080, 6320]])
  }

  @Test func blanksAndPunctuationGiveNoSpan() {
    let tokens = [
      TokenTiming(token: "<blank>", tokenId: 0, startTime: 0, endTime: 1, confidence: 1),
      TokenTiming(token: "▁,", tokenId: 1, startTime: 1, endTime: 2, confidence: 1),
      TokenTiming(token: "▁ok", tokenId: 2, startTime: 3, endTime: 3.1, confidence: 1),
      TokenTiming(token: "!", tokenId: 3, startTime: 5, endTime: 5.2, confidence: 1),
    ]
    #expect(ASREngine.wordSpansMs(tokens) == [[3000, 3100]])
  }
}
