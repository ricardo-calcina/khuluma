import Foundation
import KhulumaCore

/// Compares a native cleanup result with the CLI's, byte for byte. It was the
/// `[app] verify_pipeline` rollout check; the parity tests still use it.
enum ShadowCompare {
  /// nil when the native and CLI results agree (byte-identical text and raw
  /// text, or both found no speech), else a one-line description
  /// for app.log. A native `.needsCLI` is never compared.
  static func mismatch(
    native: CleanupOutcome, cliStatus: String, cliRawText: String, cliText: String
  ) -> String? {
    switch (native, cliStatus) {
    case (.needsCLI, _), (.noSpeech, "no_speech"):
      return nil
    case (.text(let raw, let text), "ok"):
      var diffs: [String] = []
      if !sameBytes(raw, cliRawText) {
        diffs.append("raw native=\(raw.debugDescription) cli=\(cliRawText.debugDescription)")
      }
      if !sameBytes(text, cliText) {
        diffs.append("text native=\(text.debugDescription) cli=\(cliText.debugDescription)")
      }
      return diffs.isEmpty ? nil : "pipeline mismatch: " + diffs.joined(separator: "; ")
    case (.noSpeech, _):
      return "pipeline mismatch: native=no_speech cli=\(cliStatus) text=\(cliText.debugDescription)"
    case (.text(_, let text), _):
      return "pipeline mismatch: native=ok cli=\(cliStatus) text=\(text.debugDescription)"
    }
  }

  /// Against `inline process --json` (whole take: transcription + cleanup).
  static func mismatch(native: CleanupOutcome, cli: ProcessResult) -> String? {
    mismatch(native: native, cliStatus: cli.status, cliRawText: cli.rawText, cliText: cli.text)
  }

  /// UTF-8 byte equality; String == accepts canonically equivalent text.
  static func sameBytes(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
  }
}
