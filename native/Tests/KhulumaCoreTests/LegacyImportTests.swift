import CryptoKit
import Foundation
import Testing
@testable import KhulumaCore

@Suite struct LegacyImportTests {
  struct Fixture {
    let base: URL
    let home: URL
    let root: URL
    let dest: URL
    var env: [String: String] { ["KHULUMA_CONFIG_DIR": root.path] }

    init() throws {
      base = FileManager.default.temporaryDirectory
        .appendingPathComponent("khuluma-import-\(UUID().uuidString)", isDirectory: true)
      home = base.appendingPathComponent("home", isDirectory: true)
      root = base.appendingPathComponent("cli", isDirectory: true)
      dest = base.appendingPathComponent("support", isDirectory: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func put(_ rel: String, _ text: String, mtime: Date? = nil) throws {
      let url = root.appendingPathComponent(rel)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
      if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
    }

    /// Synthetic files shaped like the CLI's (save_history, usage_record_delivery).
    func populate() throws {
      let old = Date(timeIntervalSince1970: 1_790_000_000)
      for (i, name) in ["2026-11-01T09-00-00.json", "2026-11-01T09-00-00_1.json", "2026-11-02T10-15-30.json"].enumerated() {
        try put("history/\(name)", """
          {"timestamp":"2026-11-0\(i + 1)T09:00:00","app":"TextEdit","raw":"synthetic raw \(i)","processed":"Synthetic processed \(i).",
           "metrics":{"record_ms":1200,"transcribe_ms":300,"clean_ms":5,"paste_ms":40,"total_ms":1600}}
          """, mtime: old.addingTimeInterval(Double(i) * 60))
      }
      try put("history/inline-debug/2026-11-01T09-00-00/take.wav", "RIFFfake", mtime: old)
      try put("history/inline-debug/2026-11-01T09-00-00/meta.json", "{}", mtime: old.addingTimeInterval(5))
      try put("usage.json", """
        {"schema_version":1,"delivered_dictations":{"count":42,"by_flow":{"inline":40,"tmux":2}},
         "processed_words":1234,"recording_duration_ms":98765,
         "daily":{"started_at":"2026-10-01T00:00:00Z","baseline_count":0,"days":{}},"recent_take_ids":["a"]}
        """)
      try put("vocabulary.json", #"{"revision":3,"terms":["Khuluma"]}"#)
      try put("vocabulary-backups/vocabulary-2026-10-30.json", #"{"revision":2}"#)
      try put(".cache/recorded-takes", "take-b\ntake-a\n")
      try put(".cache/recorded-takes-history", "take-a\ntake-c\n\n")
      try put(".cache/recorded-takes-bench", "take-d\n")
      try put("config.toml", "hotkey = \"fn\"\n")
      try put("vocab", "Khuluma\nParakeet\n")
    }

    func run(_ checkpoint: @escaping (LegacyImport.Checkpoint) throws -> Void = { _ in }) -> LegacyImport.Result {
      LegacyImport.run(environment: env, home: home, destination: dest, lockTimeout: 2,
                       now: Date(timeIntervalSince1970: 1_800_000_000), checkpoint: checkpoint)
    }

    func digest(_ dir: URL) -> [String: String] {
      var out: [String: String] = [:]
      let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
      for case let u as URL in e {
        let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let data = (try? Data(contentsOf: u)) ?? Data()
        out[u.path] = SHA256.hash(data: data).description + "@\(mtime)"
      }
      return out
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
  }

  func receipt(_ r: LegacyImport.Result) throws -> LegacyImport.Receipt {
    guard case .imported(let receipt) = r.outcome else { throw DataFiles.Failure("not imported: \(r.logLine)") }
    return receipt
  }

  @Test func resolvesSourceLikeTheCLI() {
    let home = URL(fileURLWithPath: "/h")
    #expect(LegacyImport.source(environment: [:], home: home).root.path == "/h/.config/khuluma")
    #expect(LegacyImport.source(environment: ["XDG_CONFIG_HOME": "/x"], home: home).root.path == "/x/khuluma")
    let s = LegacyImport.source(environment: ["XDG_CONFIG_HOME": "/x", "KHULUMA_CONFIG_DIR": "/c",
                                              "KHULUMA_USAGE_SUMMARY_FILE": "/u.json"], home: home)
    #expect(s.root.path == "/c" && s.usage.path == "/u.json")
    #expect(LegacyImport.source(environment: ["KHULUMA_CONFIG_DIR": ""], home: home).usage.path == "/h/.config/khuluma/usage.json")
  }

  @Test func fullImportCopiesEverythingAndPreservesMtimes() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let before = f.digest(f.root)
    let r = try receipt(f.run())
    #expect((r.counts.history, r.counts.history_invalid, r.counts.debug_files, r.counts.vocabulary_backups, r.counts.sounds) == (3, 0, 2, 1, 0))
    #expect(r.usage.source == LegacyImport.UsageTotals(count: 42, processed_words: 1234, recording_duration_ms: 98765))
    #expect(r.usage.imported == r.usage.source)
    #expect(r.vocabulary && r.settings == "imported" && r.legacy_take_ids == 4)
    // The top-level `hotkey` isn't a key the app reads (that's [app] hotkey).
    #expect(r.skipped == [LegacyImport.Skipped(path: f.root.appendingPathComponent("config.toml").path + " hotkey",
                                               reason: "not used by the app")])
    #expect(f.digest(f.root) == before, "source untouched")

    let fm = FileManager.default
    for rel in ["history/2026-11-01T09-00-00.json", "history/inline-debug/2026-11-01T09-00-00/take.wav",
                "usage.json", "vocabulary.json", "vocabulary-backups/vocabulary-2026-10-30.json"] {
      let s = try fm.attributesOfItem(atPath: f.root.appendingPathComponent(rel).path)
      let d = try fm.attributesOfItem(atPath: f.dest.appendingPathComponent(rel).path)
      #expect(s[.modificationDate] as? Date == d[.modificationDate] as? Date, "\(rel) mtime")
      #expect(try Data(contentsOf: f.root.appendingPathComponent(rel)) == Data(contentsOf: f.dest.appendingPathComponent(rel)))
    }
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent("config.toml").path))
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent(".import-staging").path))
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent(".import-journal.json").path))
    let ids = try JSONSerialization.jsonObject(with: Data(contentsOf: f.dest.appendingPathComponent("legacy-take-ids.json"))) as? [String]
    #expect(ids == ["take-a", "take-b", "take-c", "take-d"])
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.dest.appendingPathComponent("import.json"))) as? [String: Any]
    #expect(json?["version"] as? Int == 1 && json?["source_root"] as? String == f.root.path)
  }

  @Test func secondRunIsANoOp() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    _ = try receipt(f.run())
    let after = f.digest(f.dest)
    let second = f.run()
    #expect(second.outcome == .alreadyImported)
    #expect(f.digest(f.dest) == after)
  }

  @Test func invalidHistoryFileIsCopiedAndCounted() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    try f.put("history/2026-11-03T08-00-00.json", "{not json")
    try f.put("history/2026-11-03T08-00-01.json", "[1,2]")
    let r = try receipt(f.run())
    #expect(r.counts.history == 3 && r.counts.history_invalid == 2)
    let history = r.skipped.filter { !$0.path.contains("config.toml") }
    #expect(history.count == 2 && history.allSatisfy { $0.reason.contains("invalid history") })
    #expect(FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("history/2026-11-03T08-00-00.json").path))
  }

  @Test func unreadableUsageIsNotImported() throws {
    for bad in ["{broken",
                #"{"schema_version":1.5,"delivered_dictations":{"count":1},"processed_words":1,"recording_duration_ms":1}"#,
                #"{"schema_version":1.0,"delivered_dictations":{"count":1},"processed_words":1,"recording_duration_ms":1}"#,
                #"{"schema_version":1,"delivered_dictations":{"count":1.5},"processed_words":1,"recording_duration_ms":1}"#, #"{"schema_version":2,"delivered_dictations":{"count":1},"processed_words":1,"recording_duration_ms":1}"#,
                #"{"schema_version":1,"processed_words":1,"recording_duration_ms":1}"#] {
      let f = try Fixture(); defer { f.cleanup() }
      try f.populate()
      try f.put("usage.json", bad)
      let r = try receipt(f.run())
      #expect(r.usage.source == nil && r.usage.imported == nil)
      #expect(r.skipped.contains { $0.path.hasSuffix("usage.json") })
      #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("usage.json").path))
      #expect(r.counts.history == 3)
    }
  }

  @Test func usageFromOverridePath() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let other = f.base.appendingPathComponent("elsewhere-usage.json")
    try Data(#"{"schema_version":1,"delivered_dictations":{"count":7},"processed_words":70,"recording_duration_ms":700}"#.utf8).write(to: other)
    let r = LegacyImport.run(environment: f.env.merging(["KHULUMA_USAGE_SUMMARY_FILE": other.path]) { $1 },
                             home: f.home, destination: f.dest)
    #expect(try receipt(r).usage.imported?.count == 7)
  }

  @Test func refusesWhenAppAlreadyHasData() throws {
    for existing in ["history/2026-11-05T10-00-00.json", "usage.json"] {
      let f = try Fixture(); defer { f.cleanup() }
      try f.populate()
      let url = f.dest.appendingPathComponent(existing)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: url)
      let before = f.digest(f.dest)
      let r = f.run()
      guard case .refused = r.outcome else { Issue.record("expected refusal, got \(r.logLine)"); continue }
      #expect(f.digest(f.dest).filter { !$0.key.hasSuffix(".data.lock") } == before.filter { !$0.key.hasSuffix(".data.lock") })
      #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("import.json").path))
    }
  }

  @Test func emptyHistoryDirFromWritersIsFine() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    try FileManager.default.createDirectory(at: f.dest.appendingPathComponent("history"), withIntermediateDirectories: true)
    #expect(try receipt(f.run()).counts.history == 3)
  }

  @Test func noSourceDoesNothing() throws {
    let f = try Fixture(); defer { f.cleanup() }
    let r = f.run()
    guard case .noSource = r.outcome else { Issue.record(Comment(rawValue: r.logLine)); return }
    #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("import.json").path))
  }

  @Test(arguments: [LegacyImport.Checkpoint.staged, .moved])
  func crashThenCleanRetry(at point: LegacyImport.Checkpoint) throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let crashed = f.run { if $0 == point { throw DataFiles.Failure("simulated crash") } }
    guard case .failed = crashed.outcome else { Issue.record(Comment(rawValue: crashed.logLine)); return }
    #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("import.json").path))
    let r = try receipt(f.run())
    #expect(r.counts.history == 3 && r.usage.imported?.count == 42)
    #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent(".import-staging").path))
  }

  @Test func holdsTheDataLock() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let lock = f.dest.appendingPathComponent(".data.lock")
    let r = try DataFiles.withLock(lock, timeout: 1) {
      LegacyImport.run(environment: f.env, home: f.home, destination: f.dest, lockTimeout: 0.1)
    }
    // flock is per open file description, so a second open in-process blocks too.
    guard case .failed(let why) = r.outcome else { Issue.record(Comment(rawValue: r.logLine)); return }
    #expect(why.contains("locked"))
  }

  @Test func logLineIsOneLine() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let line = f.run().logLine
    #expect(line.hasPrefix("legacy import: done") && !line.contains("\n") && line.contains("history 3"))
  }

  // MARK: Review fixes

  func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
  }

  @Test func retryKeepsWhatTheAppWroteAfterACrash() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let sourceBefore = f.digest(f.root)
    let crashed = f.run { if $0 == .promoted("usage.json") { throw DataFiles.Failure("simulated crash") } }
    guard case .failed = crashed.outcome else { Issue.record(Comment(rawValue: crashed.logLine)); return }
    // The app runs before the retry: rewrites usage.json and a history file
    // whose name the journal lists.
    let appHistory = f.dest.appendingPathComponent("history/2026-11-01T09-00-00.json")
    let appUsage = f.dest.appendingPathComponent("usage.json")
    try write(appHistory, #"{"app":"saved by the app"}"#)
    try write(appUsage, #"{"schema_version":1,"by":"app"}"#)
    let r = f.run()
    guard case .refused(let why) = r.outcome else { Issue.record(Comment(rawValue: r.logLine)); return }
    #expect(why.contains("kept after an interrupted import"))
    #expect(try String(contentsOf: appHistory, encoding: .utf8).contains("saved by the app"))
    #expect(try String(contentsOf: appUsage, encoding: .utf8).contains("\"app\""))
    // The import's own untouched copies were removed.
    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent("history/2026-11-02T10-15-30.json").path))
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent("legacy-take-ids.json").path))
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent("history/inline-debug").path))
    #expect(!fm.fileExists(atPath: f.dest.appendingPathComponent("import.json").path))
    #expect(f.digest(f.root) == sourceBefore)
  }

  @Test func crashMidPromotionWithoutAppWritesRetriesCleanly() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    _ = f.run { if $0 == .promoted("legacy-take-ids.json") { throw DataFiles.Failure("simulated crash") } }
    let r = try receipt(f.run())
    #expect(r.counts.history == 3 && r.counts.debug_files == 2 && r.usage.imported?.count == 42)
  }

  @Test func refusesASymlinkInTheAppFolder() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let before = f.digest(f.root)
    try FileManager.default.createDirectory(at: f.dest, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: f.dest.appendingPathComponent("vocabulary-backups"),
                                               withDestinationURL: f.root.appendingPathComponent("vocabulary-backups"))
    // A journal that names the source's file through the link must not delete it.
    var st = stat()
    let backup = f.root.appendingPathComponent("vocabulary-backups/vocabulary-2026-10-30.json")
    #expect(lstat(backup.path, &st) == 0)
    try Data((LegacyImport.Identity(st).fields + "\tvocabulary-backups/vocabulary-2026-10-30.json\n").utf8)
      .write(to: f.dest.appendingPathComponent(".import-journal.json"))
    for _ in 0..<2 {
      let r = f.run()
      guard case .refused(let why) = r.outcome else { Issue.record(Comment(rawValue: r.logLine)); return }
      #expect(why.contains("symlink"))
    }
    #expect(f.digest(f.root) == before)
  }

  @Test func journalThroughASymlinkedParentKeepsTheFile() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let fm = FileManager.default
    try fm.createDirectory(at: f.dest, withIntermediateDirectories: true)
    let outside = f.base.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    let victim = outside.appendingPathComponent("x.json")
    try Data("{}".utf8).write(to: victim)
    try fm.createSymbolicLink(at: f.dest.appendingPathComponent("odd"), withDestinationURL: outside)
    var st = stat()
    #expect(lstat(victim.path, &st) == 0)
    try Data((LegacyImport.Identity(st).fields + "\todd/x.json\n").utf8)
      .write(to: f.dest.appendingPathComponent(".import-journal.json"))
    let kept = try LegacyImport.rollBackJournal(f.dest)
    #expect(fm.fileExists(atPath: victim.path) && kept.count == 1)
  }

  @Test func refusesOverlappingFolders() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let before = f.digest(f.root)
    for dest in [f.root.appendingPathComponent("app"), f.root] {
      let r = LegacyImport.run(environment: f.env, home: f.home, destination: dest, lockTimeout: 1)
      guard case .refused(let why) = r.outcome else { Issue.record(Comment(rawValue: r.logLine)); continue }
      #expect(why.contains("overlaps"))
    }
    try? FileManager.default.removeItem(at: f.root.appendingPathComponent("app"))
    try? FileManager.default.removeItem(at: f.root.appendingPathComponent(".data.lock"))
    #expect(f.digest(f.root) == before)
  }

  @Test func fifoAndSymlinkedSourceFilesAreSkipped() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let usage = f.root.appendingPathComponent("usage.json")
    try FileManager.default.removeItem(at: usage)
    #expect(mkfifo(usage.path, 0o600) == 0)
    let ledger = f.root.appendingPathComponent(".cache/recorded-takes-bench")
    try FileManager.default.removeItem(at: ledger)
    #expect(mkfifo(ledger.path, 0o600) == 0)
    let real = f.base.appendingPathComponent("real-vocab.json")
    try Data("{}".utf8).write(to: real)
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("vocabulary.json"))
    try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("vocabulary.json"), withDestinationURL: real)
    let r = try receipt(f.run())
    #expect(r.usage.source == nil && !r.vocabulary && r.legacy_take_ids == 3)
    #expect(r.skipped.filter { $0.reason.contains("regular file") }.count == 3)
    #expect(LegacyImport.lstatMode(f.dest.appendingPathComponent("usage.json")) == nil)
    #expect(LegacyImport.lstatMode(f.dest.appendingPathComponent("vocabulary.json")) == nil)
  }

  // MARK: Sounds

  /// A tiny valid WAV (a few ms of silence).
  func tinyWAV() -> Data { WAVEncoder.encode(samples: [Float](repeating: 0, count: 160)) }

  func putSound(_ f: Fixture, _ name: String, _ data: Data) throws -> URL {
    let url = f.home.appendingPathComponent(".local/share/sounds/khuluma/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  func settings(_ f: Fixture) throws -> AppSettings {
    try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: f.dest.appendingPathComponent("settings.json")))
  }

  @Test func importCopiesReferencedSoundsAndRepointsSettings() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let start = try putSound(f, "start-custom.wav", tinyWAV())
    _ = try putSound(f, "stop.WAV", tinyWAV())
    try f.put("config.toml", """
      [audio.sounds]
      start = "\(start.path)"
      stop = "$SOUNDS_DIR/khuluma/stop.WAV"
      """)
    let before = f.digest(f.home)
    let r = try receipt(f.run())
    #expect(r.counts.sounds == 2 && r.settings == "imported")
    #expect(f.digest(f.home) == before, "source sounds untouched")
    let s = try settings(f)
    #expect(s.sounds.sound("start").path == f.dest.appendingPathComponent("sounds/start.wav").path)
    #expect(s.sounds.sound("stop").path == f.dest.appendingPathComponent("sounds/stop.wav").path)
    #expect(s.sounds.sound("process").path == "")
    for event in ["start", "stop"] {
      let copy = f.dest.appendingPathComponent("sounds/\(event).wav")
      #expect(try Data(contentsOf: copy) == tinyWAV())
      var st = stat(); #expect(lstat(copy.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
    }
    var dirStat = stat(); #expect(lstat(f.dest.appendingPathComponent("sounds").path, &dirStat) == 0 && (dirStat.st_mode & 0o777) == 0o700)
    #expect(r.skipped.allSatisfy { !$0.reason.hasPrefix("sound ") })
    #expect(LegacyImport.Result(outcome: .imported(r), duration: 0).logLine.contains("sounds 2"))
  }

  @Test func anUnreadableSoundIsSkippedAndTheImportStillFinishes() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let locked = try putSound(f, "locked.wav", tinyWAV())
    #expect(chmod(locked.path, 0) == 0)
    defer { chmod(locked.path, 0o600) }
    try f.put("config.toml", "[audio.sounds]\nstart = \"\(locked.path)\"\n")
    let r = try receipt(f.run())
    #expect(r.counts.sounds == 0 && r.settings == "imported")
    #expect(r.skipped.contains { $0.path == locked.path && $0.reason.hasPrefix("sound start:") })
    #expect(try settings(f).sounds.sound("start").path == "")
    #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("sounds").path))
  }

  /// A crash right after the sounds moved (or just before) is undone by the
  /// journal, and the next run finishes and writes the receipt.
  @Test(arguments: ["promoting", "promoted"])
  func crashAroundPromotingSoundsRetriesCleanly(when: String) throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let start = try putSound(f, "start.wav", tinyWAV())
    try f.put("config.toml", "[audio.sounds]\nstart = \"\(start.path)\"\n")
    struct Crash: Error {}
    let first = f.run { point in
      if (when == "promoting" && point == .promoting("sounds")) || (when == "promoted" && point == .promoted("sounds")) { throw Crash() }
    }
    guard case .failed = first.outcome else { Issue.record("expected the crash to fail the run"); return }
    #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("import.json").path))
    let r = try receipt(f.run())
    #expect(r.counts.sounds == 1)
    #expect(try Data(contentsOf: f.dest.appendingPathComponent("sounds/start.wav")) == tinyWAV())
    #expect(try settings(f).sounds.sound("start").path == f.dest.appendingPathComponent("sounds/start.wav").path)
  }

  @Test func importRefusesUnsafeSoundsAndKeepsTheBundledDefault() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let real = try putSound(f, "real.wav", tinyWAV())
    let link = f.home.appendingPathComponent(".local/share/sounds/khuluma/link.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let big = try putSound(f, "big.wav", Data(count: 10 * 1024 * 1024 + 1))
    let text = try putSound(f, "notes.txt", Data("not audio".utf8))
    let missing = f.home.appendingPathComponent(".local/share/sounds/khuluma/gone.wav")
    try f.put("config.toml", """
      [audio.sounds]
      start = "\(link.path)"
      stop = "\(big.path)"
      process = "\(text.path)"
      cancel = "\(missing.path)"
      error = "\(real.path)"
      """)
    let r = try receipt(f.run())
    #expect(r.counts.sounds == 1)
    let s = try settings(f)
    for event in ["start", "stop", "process", "cancel"] { #expect(s.sounds.sound(event).path == "", "\(event)") }
    #expect(s.sounds.sound("error").path == f.dest.appendingPathComponent("sounds/error.wav").path)
    let reasons = Dictionary(uniqueKeysWithValues: r.skipped.filter { $0.reason.hasPrefix("sound ") }.map { ($0.path, $0.reason) })
    #expect(reasons[link.path]?.contains("sound start: not a regular file") == true)
    #expect(reasons[big.path]?.contains("sound stop: larger than 10 MB") == true)
    #expect(reasons[text.path]?.contains("sound process: not an audio file") == true)
    #expect(reasons[missing.path]?.contains("sound cancel: file not found") == true)
    let files = try FileManager.default.contentsOfDirectory(atPath: f.dest.appendingPathComponent("sounds").path)
    #expect(files == ["error.wav"])
    #expect(FileManager.default.fileExists(atPath: link.path) && FileManager.default.fileExists(atPath: big.path))
  }

  @Test func copiesArePrivate() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    for rel in ["vocabulary.json", "history/2026-11-01T09-00-00.json"] {
      _ = chmod(f.root.appendingPathComponent(rel).path, 0o644)
    }
    _ = try receipt(f.run())
    func mode(_ rel: String) -> mode_t {
      var st = stat(); lstat(f.dest.appendingPathComponent(rel).path, &st); return st.st_mode & 0o777
    }
    for rel in ["vocabulary.json", "usage.json", "history/2026-11-01T09-00-00.json",
                "history/inline-debug/2026-11-01T09-00-00/take.wav", "legacy-take-ids.json"] {
      #expect(mode(rel) == 0o600, "\(rel)")
    }
    for rel in ["history", "history/inline-debug", "history/inline-debug/2026-11-01T09-00-00", "vocabulary-backups"] {
      #expect(mode(rel) == 0o700, "\(rel)")
    }
  }

  @Test func largeDebugArchiveTiming() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let fm = FileManager.default
    for d in 0..<100 {
      let dir = f.root.appendingPathComponent("history/inline-debug/2026-11-03T10-\(d)", isDirectory: true)
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      for i in 0..<50 { try Data(repeating: UInt8(i), count: 512).write(to: dir.appendingPathComponent("f\(i).bin")) }
    }
    let r = f.run()
    let receipt = try receipt(r)
    #expect(receipt.counts.debug_files == 5002)
    print("legacy import of 5,002 debug files took \(Int(r.duration * 1000)) ms")
    #expect(r.duration < 60)
  }

  @Test func importsTheLegacyVocabList() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let r = try receipt(f.run())
    #expect(r.legacy_vocab)
    let copy = f.dest.appendingPathComponent("vocab")
    #expect(try Data(contentsOf: copy) == Data(contentsOf: f.root.appendingPathComponent("vocab")))
    var st = stat(); lstat(copy.path, &st)
    #expect(st.st_mode & 0o777 == 0o600)
  }

  @Test func legacyVocabMustBeARegularFileAndNotAlreadyInTheApp() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let src = f.root.appendingPathComponent("vocab")
    try FileManager.default.removeItem(at: src)
    #expect(mkfifo(src.path, 0o600) == 0)
    let r = try receipt(f.run())
    #expect(!r.legacy_vocab && r.skipped.contains { $0.path == src.path })

    let g = try Fixture(); defer { g.cleanup() }
    try g.populate()
    try write(g.dest.appendingPathComponent("vocab"), "mine\n")
    guard case .refused(let why) = g.run().outcome else { Issue.record("expected refusal"); return }
    #expect(why.contains("vocab"))
  }

  @Test func failedDirectorySyncFailsBeforeTheReceipt() throws {
    let f = try Fixture(); defer { f.cleanup() }
    try f.populate()
    let r = LegacyImport.$syncOverride.withValue({ _ in throw DataFiles.Failure("simulated fsync failure") }) {
      f.run()
    }
    guard case .failed(let why) = r.outcome else { Issue.record(Comment(rawValue: r.logLine)); return }
    #expect(why.contains("simulated fsync failure"))
    #expect(!FileManager.default.fileExists(atPath: f.dest.appendingPathComponent("import.json").path))
    #expect(try receipt(f.run()).counts.history == 3)
  }
}
