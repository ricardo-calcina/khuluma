import Foundation
import Testing
@testable import KhulumaCore

/// Every take is transcribed by the app or kept; nothing goes elsewhere.
struct TakeRouteTests {
  private func config(_ transcription: String) throws -> AppConfig {
    try AppConfigFixture.decode(AppConfigFixture.json.replacingOccurrences(
      of: #""transcription":{"socket_path""#, with: #""transcription":{"# + transcription + #""socket_path""#))
  }

  @Test func readySettingsGoNative() throws {
    #expect(TakeRoute.decide(config: try AppConfigFixture.decode()) == .native)
  }

  @Test func scribeGoesToScribeEvenWithoutAVisibleKey() throws {
    #expect(TakeRoute.decide(config: try config(#""provider":"elevenlabs","key_available":false,"#)) == .scribe)
  }

  @Test func noSettingsKeepsTheTake() {
    #expect(TakeRoute.decide(config: nil, problem: "timed out reading settings")
            == .keep(KeptTake(reason: "timed out reading settings", category: "settings_unavailable")))
  }

  @Test func noModelKeepsTheTake() throws {
    let noModel = try AppConfigFixture.decode(AppConfigFixture.json.replacingOccurrences(
      of: #""model_path":"/m","#, with: #""model_path":null,"#))
    #expect(TakeRoute.decide(config: noModel)
            == .keep(KeptTake(reason: TranscriptionSettings.modelMissing, category: "model_missing")))
  }

  @Test func unknownProviderKeepsTheTake() throws {
    #expect(TakeRoute.decide(config: try config(#""provider":"whisper","#))
            == .keep(KeptTake(reason: "unsupported transcription provider", category: "not_supported")))
  }

  @Test func nativeFailuresKeepTheTakeWithFixedCategories() {
    #expect(KeptTake.afterNativeFailure(DaemonClient.ClientError.protocolError("x")).category == "daemon_protocol")
    #expect(KeptTake.afterNativeFailure(DaemonClient.ClientError.daemon(code: "bad", message: "secret")).reason
            == "transcription failed (daemon error bad)")
    #expect(KeptTake.afterNativeFailure(DaemonClient.ClientError.unreachable("x")).category == "daemon_unreachable")
    struct Other: Error {}
    #expect(KeptTake.afterNativeFailure(Other()).category == "transcription_failed")
  }
}
