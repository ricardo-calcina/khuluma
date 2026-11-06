import Foundation
@testable import KhulumaCore

/// A complete AppConfig as JSON; tests rewrite parts of it with
/// `replacingOccurrences`.
enum AppConfigFixture {
  static let json = #"""
  {"schema_version":1,"hotkey":"ctrl+option+space",
   "sounds":{"start":{"enabled":true,"path":"/s/start.wav"},"cancel":{"enabled":false,"path":null}},
   "inline":{"autosend":true,"send_mode":"enter","paste_target":"current","process_sound":true,"activate_delay_ms":90,"send_delay_ms":35},
   "cleanup":{"config_dir":"/c","clean":"0","repeats_level":"1","vocab_clean":"1","british_spelling":"1",
     "locale_ctype":"","locale_collate":""},
   "transcription":{"socket_path":"/s.sock","model_path":"/m","model_version":"v3","model_label":"m","language":"en",
     "tail_pad_ms":"500","tail_rescue":true,"tail_rescue_ms":"","tail_rescue_min_ms":"",
     "keep_logs":false,"ffmpeg":true,"timeout_seconds":"600","processing_dir":"/p"},
   "config":{"error":null,"source":"file"},
   "pipeline":{"supervise":true},
   "usage":{"summary_path":"/c/usage.json"}}
  """#

  static func decode(_ json: String = json) throws -> AppConfig {
    try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
  }
}
