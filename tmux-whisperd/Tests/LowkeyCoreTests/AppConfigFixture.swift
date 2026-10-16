import Foundation
@testable import LowkeyCore

/// A complete `app-config --json` as the CLI writes it today; tests rewrite
/// parts of it with `replacingOccurrences`.
enum AppConfigFixture {
  static let json = #"""
  {"schema_version":1,"app_contract":2,"cli_version":"0.10.0-dev","hotkey":"ctrl+option+space",
   "sounds":{"start":{"enabled":true,"path":"/s/start.wav"},"cancel":{"enabled":false,"path":null}},
   "inline":{"autosend":true,"send_mode":"enter","paste_target":"current","process_sound":true,"activate_delay_ms":90,"send_delay_ms":35},
   "cleanup":{"config_dir":"/c","clean":"0","repeats_level":"1","vocab_clean":"1","british_spelling":"1",
     "code_paragraph_min_words":"70","long_paragraph_min_words":"55","force_mode":null,
     "locale_ctype":"","locale_collate":""},
   "transcription":{"socket_path":"/s.sock","model_path":"/m","model_version":"v3","model_label":"m","language":"en",
     "tail_pad_ms":"500","tail_rescue":true,"tail_rescue_ms":"","tail_rescue_min_ms":"",
     "keep_logs":false,"ffmpeg":true,"timeout_seconds":"600","processing_dir":"/p"},
   "config":{"error":null,"source":"file"},
   "pipeline":{"supervise":true},
   "usage":{"summary_path":"/c/usage.json"}}
  """#

  static func decode(_ json: String = json) throws -> AppConfig {
    try AppContract.decodeAppConfig(Data(json.utf8))
  }
}
