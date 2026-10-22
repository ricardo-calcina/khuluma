import Foundation

/// Cleanup settings as the CLI resolves them (env, ~/.zshenv, config.toml):
/// the `cleanup` section of `khuluma app-config --json`.
///
/// Values stay raw strings and are interpreted here with the CLI's own rules,
/// so odd values ("2abc", "TRUE", "007") behave identically.
public struct CleanupSettings: Codable, Equatable, Sendable {
  public var configDir: String
  /// `KHULUMA_CLEAN`: fillers/repeats run only when exactly "1".
  public var clean: String
  /// `KHULUMA_REPEATS_LEVEL` / `[clean] repeats_level`.
  public var repeatsLevel: String
  /// `KHULUMA_VOCAB_CLEAN` (bool_is_on).
  public var vocabClean: String
  /// `KHULUMA_BRITISH_SPELLING`: off for 0/off/false/no.
  public var britishSpelling: String
  /// The CLI's effective LC_CTYPE / LC_COLLATE (LC_ALL, else the category,
  /// else LANG; "" when unset). The blank check and the filters' character
  /// classes depend on them; only the C locale is reproduced natively.
  public var localeCtype: String?
  public var localeCollate: String?

  public init(
    configDir: String, clean: String = "0", repeatsLevel: String = "1", vocabClean: String = "1",
    britishSpelling: String = "1", localeCtype: String? = nil, localeCollate: String? = nil
  ) {
    self.configDir = configDir
    self.clean = clean
    self.repeatsLevel = repeatsLevel
    self.vocabClean = vocabClean
    self.britishSpelling = britishSpelling
    self.localeCtype = localeCtype
    self.localeCollate = localeCollate
  }

  enum CodingKeys: String, CodingKey {
    case configDir = "config_dir"
    case clean
    case repeatsLevel = "repeats_level"
    case vocabClean = "vocab_clean"
    case britishSpelling = "british_spelling"
    case localeCtype = "locale_ctype"
    case localeCollate = "locale_collate"
  }

  /// The native pipeline can't reproduce this configuration; use the CLI.
  public var requiresCLI: Bool {
    !CleanupSettings.isCLocale(localeCtype) || !CleanupSettings.isCLocale(localeCollate)
  }

  static func isCLocale(_ value: String?) -> Bool {
    ["", "C", "POSIX"].contains(value ?? "")
  }

  var fillersEnabled: Bool { clean == "1" }
  /// Any level other than the literal "0" runs the repeats filter, even one
  /// Perl reads as 0 (which still normalises whitespace).
  var repeatsFilterEnabled: Bool { repeatsLevel != "0" }
  var vocabEnabled: Bool { PerlText.boolIsOn(vocabClean) }
}

/// Result of cleaning one inline transcript.
public enum CleanupOutcome: Equatable, Sendable {
  /// `raw` is the text after the first pass (what history stores as raw);
  /// `text` is the final text to deliver.
  case text(raw: String, text: String)
  /// Nothing left after artefact/filler cleanup ("No speech detected").
  case noSpeech
  /// The CLI runs in a non-C locale: only the CLI can produce the result.
  case needsCLI
}

/// Swift port of the inline cleanup in `process_inline_recording`
/// (`cleanup_raw_transcript`, `finish_transcript_text`),
/// stage for stage, including bash's `$(...)` newline stripping between
/// stages. Proven byte-identical by tests/fixtures/cleanup.
public struct TextPipeline: Sendable {
  public let settings: CleanupSettings

  public init(settings: CleanupSettings) {
    self.settings = settings
  }

  /// `transcript` is the transcriber's output.
  public func process(transcript: String) -> CleanupOutcome {
    if settings.requiresCLI { return .needsCLI }
    let raw = cleanRaw(PerlText.bashCapture(transcript))
    if PerlText.isBlank(raw) { return .noSpeech }
    return .text(raw: raw, text: finish(raw))
  }

  /// `cleanup_raw_transcript`.
  func cleanRaw(_ text: String) -> String {
    var out = PerlText.bashCapture(TextCleanup.sanitizeArtifacts(text))
    if settings.fillersEnabled {
      out = PerlText.bashCapture(TextCleanup.cleanFillers(out))
      if settings.repeatsFilterEnabled {
        let level = PerlText.perlInt(settings.repeatsLevel)
        out = PerlText.bashCapture(TextCleanup.cleanRepeats(out, level: level))
      }
    }
    return out
  }

  /// `finish_transcript_text`.
  func finish(_ text: String) -> String {
    var out = text
    if settings.vocabEnabled {
      out = PerlText.bashCapture(VocabCorrector(configDir: settings.configDir).apply(out))
    }
    return PerlText.bashCapture(TextCleanup.normalizeBritishSpelling(out, enabled: settings.britishSpelling))
  }
}
