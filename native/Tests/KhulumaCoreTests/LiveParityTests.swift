import Foundation
import Testing
@testable import KhulumaCore

/// Opt-in end-to-end check against a running khulumad: the native path
/// (DaemonClient + NativeTranscriber + TextPipeline) must produce the same
/// bytes as `khuluma inline process` on the same WAVs.
///
/// KHULUMA_LIVE_PARITY_DIR must contain wav/<n>.wav, and for
/// each variant out/<variant>/app-config.json plus out/<variant>/<n>.json
/// (the `inline process --json` result). Skipped when unset (CI).
struct LiveParityTests {
  static let directory = ProcessInfo.processInfo.environment["KHULUMA_LIVE_PARITY_DIR"]

  static func samples(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    let pcm: [Int16] = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    #expect(!pcm.contains(Int16.min), "Int16.min does not survive the Float round trip")
    return pcm.map { Float($0) / 32767 }
  }

  @Test(.enabled(if: directory != nil)) func nativeMatchesInlineProcess() throws {
    let root = URL(fileURLWithPath: try #require(Self.directory))
    let fm = FileManager.default
    let wavs = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("wav").path)
      .filter { $0.hasSuffix(".wav") }.sorted()
    let variants = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("out").path).sorted()
    var compared = 0
    for variant in variants {
      let out = root.appendingPathComponent("out/\(variant)")
      let config = try AppContract.decodeAppConfig(Data(contentsOf: out.appendingPathComponent("app-config.json")))
      #expect(config.nativePipelineBlocker == nil, "\(variant): \(config.nativePipelineBlocker ?? "")")
      let transcription = config.transcription
      let cleanup = config.cleanup
      let client = DaemonClient(socketPath: transcription.socketPath)
      for name in wavs {
        let stem = String(name.dropLast(4))
        let expected = try JSONDecoder().decode(
          ProcessResult.self, from: Data(contentsOf: out.appendingPathComponent("\(stem).json")))
        let started = Date()
        let transcribed = try NativeTranscriber(settings: transcription).transcribe(
          samples: try Self.samples(root.appendingPathComponent("wav/\(name)"))
        ) { wav, flow in
          try client.transcribe(wav: wav, language: transcription.language, flow: flow,
                                modelPath: transcription.modelPath ?? "", modelVersion: transcription.modelVersion,
                                timeout: 120)
        }
        let outcome = TextPipeline(settings: cleanup).process(transcript: transcribed.transcript)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        print("live \(variant)/\(stem): native \(elapsed)ms vs CLI transcribe \(expected.timings["transcribe_ms"] ?? -1)ms"
              + (transcribed.tailRescueMs != nil ? " (tail rescue)" : ""))
        let mismatch = ShadowCompare.mismatch(native: outcome, cli: expected)
        #expect(mismatch == nil, "\(variant)/\(stem): \(mismatch ?? "")")
        compared += 1
      }
    }
    #expect(compared > 0)
  }
}
