import Foundation

/// Cleanup settings as the CLI resolves them (env, ~/.zshenv, config.toml):
/// the `cleanup` section of `tmux-whisper app-config --json`.
///
/// Values stay raw strings and are interpreted here with the CLI's own rules,
/// so odd values ("2abc", "TRUE", "007") behave identically.
public struct CleanupSettings: Codable, Equatable, Sendable {
  public var configDir: String
  /// `DICTATE_CLEAN`: fillers/repeats run only when exactly "1".
  public var clean: String
  /// `DICTATE_REPEATS_LEVEL` / `[clean] repeats_level`.
  public var repeatsLevel: String
  /// `DICTATE_VOCAB_CLEAN` (bool_is_on).
  public var vocabClean: String
  /// `DICTATE_BRITISH_SPELLING`: off for 0/off/false/no.
  public var britishSpelling: String
  public var codeParagraphMinWords: String
  public var longParagraphMinWords: String
  /// `DICTATE_FORCE_MODE`, if set.
  public var forceMode: String?
  /// The CLI's effective LC_CTYPE / LC_COLLATE (LC_ALL, else the category,
  /// else LANG; "" when unset). grep -i, sed trimming, glob order and the
  /// blank check depend on them; only the C locale is reproduced natively.
  public var localeCtype: String?
  public var localeCollate: String?

  public init(
    configDir: String, clean: String = "0", repeatsLevel: String = "1", vocabClean: String = "1",
    britishSpelling: String = "1", codeParagraphMinWords: String = "70", longParagraphMinWords: String = "55",
    forceMode: String? = nil, localeCtype: String? = nil, localeCollate: String? = nil
  ) {
    self.configDir = configDir
    self.clean = clean
    self.repeatsLevel = repeatsLevel
    self.vocabClean = vocabClean
    self.britishSpelling = britishSpelling
    self.codeParagraphMinWords = codeParagraphMinWords
    self.longParagraphMinWords = longParagraphMinWords
    self.forceMode = forceMode
    self.localeCtype = localeCtype
    self.localeCollate = localeCollate
  }

  enum CodingKeys: String, CodingKey {
    case configDir = "config_dir"
    case clean
    case repeatsLevel = "repeats_level"
    case vocabClean = "vocab_clean"
    case britishSpelling = "british_spelling"
    case codeParagraphMinWords = "code_paragraph_min_words"
    case longParagraphMinWords = "long_paragraph_min_words"
    case forceMode = "force_mode"
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
  case text(raw: String, text: String, mode: String)
  /// Nothing left after artefact/filler cleanup ("No speech detected").
  case noSpeech
  /// The CLI runs in a non-C locale: only the CLI can produce the result.
  case needsCLI
}

/// Swift port of the inline cleanup in `process_inline_recording`
/// (`cleanup_raw_transcript`, `resolve_inline_mode`, `finish_transcript_text`),
/// stage for stage, including bash's `$(...)` newline stripping between
/// stages. Proven byte-identical by tests/fixtures/cleanup.
public struct TextPipeline: Sendable {
  public let settings: CleanupSettings

  public init(settings: CleanupSettings) {
    self.settings = settings
  }

  /// `transcript` is the transcriber's output; `app` the target app's name.
  public func process(transcript: String, app: String?) -> CleanupOutcome {
    if settings.requiresCLI { return .needsCLI }
    let raw = cleanRaw(PerlText.bashCapture(transcript))
    if PerlText.isBlank(raw) { return .noSpeech }
    let mode = ModeResolver(configDir: settings.configDir)
      .resolveInlineMode(app: app, forceMode: settings.forceMode)
    return .text(raw: raw, text: finish(raw, mode: mode), mode: mode)
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
  func finish(_ text: String, mode: String) -> String {
    var out = text
    if settings.vocabEnabled {
      out = PerlText.bashCapture(VocabCorrector(configDir: settings.configDir, mode: mode).apply(out))
    }
    // apply_mode_cleanup matches the mode name exactly.
    switch mode {
    case "code":
      out = PerlText.bashCapture(
        TextCleanup.autoParagraphs(out, mode: mode, minWords: settings.codeParagraphMinWords))
    case "long":
      out = PerlText.bashCapture(
        TextCleanup.autoParagraphs(out, mode: mode, minWords: settings.longParagraphMinWords))
    default:
      break
    }
    return PerlText.bashCapture(TextCleanup.normalizeBritishSpelling(out, enabled: settings.britishSpelling))
  }
}
