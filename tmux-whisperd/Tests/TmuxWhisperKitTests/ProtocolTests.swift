import Foundation
import Testing
@testable import TmuxWhisperKit

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
