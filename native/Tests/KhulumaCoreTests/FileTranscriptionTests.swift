import AVFoundation
import Darwin
import Foundation
import Testing
@testable import KhulumaCore

private func scratch() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-ft-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func tone(seconds: Double, rate: Double = 16_000) -> [Float] {
  (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate)) * 0.3 }
}

/// A WAV or m4a through AVAudioFile (any rate/channels/codec).
private func writeAudio(_ url: URL, seconds: Double, rate: Double, channels: AVAudioChannelCount, aac: Bool) throws {
  var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
  if aac {
    settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
  } else {
    settings[AVFormatIDKey] = kAudioFormatLinearPCM
    settings[AVLinearPCMBitDepthKey] = 16
    settings[AVLinearPCMIsFloatKey] = false
  }
  let file = try AVAudioFile(forWriting: url, settings: settings)
  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
  let frames = AVAudioFrameCount(seconds * rate)
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
  buffer.frameLength = frames
  let samples = tone(seconds: seconds, rate: rate)
  for channel in 0..<Int(channels) {
    for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = samples[i] }
  }
  try file.write(from: buffer)
}

private func fakeEngine(_ answer: @escaping @Sendable (URL, String) throws -> String) -> FileTranscriber.Engine {
  FileTranscriber.Engine(name: "swift_parakeet", model: "parakeet-tdt-0.6b-v3") { wav, flow, _ in try answer(wav, flow) }
}

final class Flows: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ flow: String) { lock.withLock { items.append(flow) } }
  var all: [String] { lock.withLock { items } }
}

struct FileTranscribeOptionsTests {
  func run(_ args: [String]) throws -> FileTranscribeOptions {
    guard case .run(let options) = try FileTranscribeOptions.parse(args) else { throw FileTranscribeOptions.UsageError("help") }
    return options
  }

  func usageError(_ args: [String]) -> FileTranscribeOptions.UsageError? {
    do { _ = try FileTranscribeOptions.parse(args); return nil } catch { return error as? FileTranscribeOptions.UsageError }
  }

  @Test func parsesTheKeepList() throws {
    let options = try run(["a.m4a", "-q", "--format", "json", "--beside", "--force", "b.mp3"])
    #expect(options.inputs == ["a.m4a", "b.mp3"])
    #expect(options.quiet && options.beside && options.force && options.format == .json)
    #expect(try run(["--format=txt", "-o", "out.txt", "a.wav"]).output == "out.txt")
    #expect(try run(["--output=out.txt", "a.wav"]).output == "out.txt")
    #expect(try run(["--", "-odd.wav"]).inputs == ["-odd.wav"])
    #expect(try FileTranscribeOptions.parse(["--help"]) == .help)
  }

  @Test func refusesDroppedFlagsClearly() {
    for args in [["-c", "a.wav"], ["--clipboard", "a.wav"], ["--out-dir", "d", "a.wav"], ["--out-dir=d", "a.wav"],
                 ["--no-tail-rescue", "a.wav"], ["-"], ["a.wav", "-"]] {
      let error = usageError(args)
      #expect(error?.exitCode == 2, "\(args)")
      #expect(error?.message.contains("no longer supported") == true, "\(args)")
    }
  }

  @Test func refusesBadCombinations() {
    #expect(usageError(["-o", "x.txt", "a.wav", "b.wav"])?.message.contains("single input") == true)
    #expect(usageError(["-o", "x.txt", "--beside", "a.wav"])?.message.contains("only one of") == true)
    #expect(usageError(["--format", "srt", "a.wav"])?.message == "transcribe: --format must be txt or json")
    #expect(usageError(["--bogus", "a.wav"])?.message.contains("unknown option: --bogus") == true)
    #expect(usageError(["-o"])?.message == "transcribe: -o requires a file path")
    #expect(usageError([])?.showUsage == true)
    #expect(usageError([])?.exitCode == 2)
  }
}

struct TranscriptOutputTests {
  @Test func besideNamingFollowsTheCLI() {
    #expect(TranscriptOutput.besidePath(for: "/a/memo.m4a", ext: "txt") == "/a/memo.txt")
    #expect(TranscriptOutput.besidePath(for: "/a/x.tar.gz", ext: "json") == "/a/x.tar.json")
    #expect(TranscriptOutput.besidePath(for: "/a/.hidden", ext: "txt") == "/a/.hidden.txt")
    #expect(TranscriptOutput.besidePath(for: "noext", ext: "txt") == "noext.txt")
    #expect(TranscriptOutput.destination(for: "a.wav", output: nil, beside: false, ext: "txt") == nil)
    #expect(TranscriptOutput.destination(for: "a.wav", output: "o.txt", beside: false, ext: "txt") == "o.txt")
  }

  @Test func neverOverwritesWithoutForce() throws {
    let dir = try scratch()
    let dest = dir.appendingPathComponent("t.txt").path
    try "old\n".write(toFile: dest, atomically: true, encoding: .utf8)
    #expect(throws: TranscriptOutput.Failure(TranscriptOutput.existsMessage(dest))) {
      try TranscriptOutput.write("new", to: dest, force: false)
    }
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "old\n")
    try TranscriptOutput.write("new", to: dest, force: true)
    #expect(try String(contentsOfFile: dest, encoding: .utf8) == "new\n")
    let fresh = dir.appendingPathComponent("sub/fresh.txt").path
    try TranscriptOutput.write("hi", to: fresh, force: false)
    #expect(try String(contentsOfFile: fresh, encoding: .utf8) == "hi\n")
    // No temp files left behind.
    let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".khuluma-transcript") }
    #expect(left.isEmpty)
    try? FileManager.default.removeItem(at: dir)
  }

  @Test func failedWriteLeavesNothing() throws {
    let dir = try scratch()
    let locked = dir.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    chmod(locked.path, 0o500)
    defer { chmod(locked.path, 0o700); try? FileManager.default.removeItem(at: dir) }
    let dest = locked.appendingPathComponent("t.txt").path
    #expect(throws: TranscriptOutput.Failure("cannot write output: \(dest)")) {
      try TranscriptOutput.write("text", to: dest, force: false)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
  }

  @Test func precheckRefusesTheInputItself() throws {
    let dir = try scratch()
    let input = dir.appendingPathComponent("a.txt").path
    try "x".write(toFile: input, atomically: true, encoding: .utf8)
    #expect(throws: TranscriptOutput.Failure("refusing to overwrite the input file: \(input)")) {
      try TranscriptOutput.precheck(destination: input, input: input, force: true)
    }
    try? FileManager.default.removeItem(at: dir)
  }

  @Test func jsonLineMatchesPythonDumps() throws {
    let transcript = FileTranscriber.Transcript(text: "Hi \"there\"\nnew/line é\u{01}", audioDurationMs: 4396,
                                                processingMs: 293, model: "parakeet-tdt-0.6b-v3", engine: "swift_parakeet")
    let line = TranscriptOutput.jsonLine(file: "memo.m4a", transcript: transcript)
    #expect(line == #"{"file": "memo.m4a", "text": "Hi \"there\"\nnew/line é\u0001", "audio_duration_ms": 4396, "processing_ms": 293, "model": "parakeet-tdt-0.6b-v3", "engine": "swift_parakeet"}"#)
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    #expect(Set(object?.keys ?? [:].keys) == ["file", "text", "audio_duration_ms", "processing_ms", "model", "engine"])
    #expect(object?["text"] as? String == transcript.text)
  }
}

struct AudioFileDecoderTests {
  @Test func decodesWAVToPadded16kMono() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("short.wav")
    try WAVEncoder.encode(samples: tone(seconds: 0.5)).write(to: input)
    let decoded = try AudioFileDecoder.decode(input, to: dir.appendingPathComponent("out.wav"))
    #expect(decoded.decodedSamples == 8000)
    #expect(decoded.samples == AudioFileDecoder.minimumSamples)
    #expect(decoded.durationMs == 1050)
    let file = try AVAudioFile(forReading: decoded.wav)
    #expect(file.fileFormat.sampleRate == 16_000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.length == AVAudioFramePosition(AudioFileDecoder.minimumSamples))
    let data = try Data(contentsOf: decoded.wav)
    #expect(data.count == 44 + AudioFileDecoder.minimumSamples * 2)
  }

  @Test func resamplesStereoWAVAndM4A() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, aac) in [("stereo.wav", false), ("memo.m4a", true)] {
      let input = dir.appendingPathComponent(name)
      try writeAudio(input, seconds: 2, rate: 44_100, channels: 2, aac: aac)
      let decoded = try AudioFileDecoder.decode(input, to: dir.appendingPathComponent("\(name).out.wav"))
      // AAC adds priming/padding frames; allow a little slack.
      #expect(abs(decoded.samples - 32_000) < 2_000, "\(name): \(decoded.samples)")
      let file = try AVAudioFile(forReading: decoded.wav)
      #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1, "\(name)")
    }
  }

  @Test func unreadableFilesFailAndLeaveNoWAV() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("notes.m4a")
    try "not audio".write(to: input, atomically: true, encoding: .utf8)
    let out = dir.appendingPathComponent("out.wav")
    #expect(throws: AudioFileDecoder.DecodeError.self) { try AudioFileDecoder.decode(input, to: out) }
    #expect(!FileManager.default.fileExists(atPath: out.path))
  }

  @Test func tailIsTheLastWindow() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pcm = (0..<48_000).map { Int16(truncatingIfNeeded: $0) }
    let input = dir.appendingPathComponent("in.wav")
    try WAVEncoder.encode(pcm: pcm).write(to: input)
    let decoded = try AudioFileDecoder.decode(input, to: dir.appendingPathComponent("d.wav"))
    let tail = dir.appendingPathComponent("tail.wav")
    try AudioFileDecoder.writeTail(of: decoded, windowMs: 1000, to: tail)
    let data = try Data(contentsOf: tail)
    let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    #expect(samples == Array(pcm.suffix(16_000)))
  }
}

struct FileTranscriberTests {
  func wav(_ dir: URL, seconds: Double) throws -> URL {
    let url = dir.appendingPathComponent("in-\(seconds).wav")
    try WAVEncoder.encode(samples: tone(seconds: seconds)).write(to: url)
    return url
  }

  @Test func shortFilesTakeOnePassAndAreSanitized() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let flows = Flows()
    let engine = fakeEngine { _, flow in flows.add(flow); return "Hello [blank audio] there .\n" }
    let result = try FileTranscriber().transcribe(try wav(dir, seconds: 3), label: "x", workDirectory: dir, engine: engine)
    #expect(flows.all == ["file"])
    #expect(result.text == "Hello there.")
    #expect(result.audioDurationMs == 3000)
    #expect(result.engine == "swift_parakeet" && result.model == "parakeet-tdt-0.6b-v3")
    // Only the input is left: the decoded WAVs are gone.
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
  }

  @Test func longFilesGetTheTailRescue() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let flows = Flows()
    let engine = fakeEngine { _, flow in
      flows.add(flow)
      return flow == "file" ? "one two three four five" : "four five six"
    }
    let result = try FileTranscriber().transcribe(try wav(dir, seconds: 13), label: "x", workDirectory: dir, engine: engine)
    #expect(flows.all == ["file", "file-tail"])
    #expect(result.text == "one two three four five six")
  }

  @Test func failuresUseTheCLIsWords() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = try wav(dir, seconds: 2)
    #expect(throws: FileTranscriber.Failure("no speech detected in: memo")) {
      try FileTranscriber().transcribe(input, label: "memo", workDirectory: dir, engine: fakeEngine { _, _ in " [blank audio] " })
    }
    struct Boom: Error {}
    #expect(throws: FileTranscriber.Failure.self) {
      try FileTranscriber().transcribe(input, label: "memo", workDirectory: dir, engine: fakeEngine { _, _ in throw Boom() })
    }
  }

  @Test func engineChoice() {
    let model = (path: "/m/parakeet-tdt-0.6b-v3", version: "v3")
    let holding = DaemonStatus(version: "0.3.0", modelLoaded: .init(path: model.path, version: "v3"))
    let other = DaemonStatus(version: "0.3.0", modelLoaded: .init(path: "/other", version: "v3"))
    #expect(FileEngineChoice.choose(model: model, daemon: holding) == .daemon)
    #expect(FileEngineChoice.choose(model: model, daemon: other) == .inProcess)
    #expect(FileEngineChoice.choose(model: model, daemon: DaemonStatus(version: "0.2.0")) == .inProcess)
    #expect(FileEngineChoice.choose(model: model, daemon: nil) == .inProcess)
    #expect(FileEngineChoice.choose(model: nil, daemon: holding) == .noModel)
  }

  @Test func formatsDurationsLikeTheCLI() {
    #expect(FileTranscriber.formatDuration(4396) == "4s")
    #expect(FileTranscriber.formatDuration(125_000) == "2m 05s")
    #expect(FileTranscriber.formatDuration(3_725_000) == "1h 02m 05s")
  }
}

final class Captured: @unchecked Sendable {
  var out = "", err = ""
}

struct FileTranscribeCommandTests {
  func command(_ captured: Captured, engine: @escaping () throws -> FileTranscriber.Engine) -> FileTranscribeCommand {
    FileTranscribeCommand(stdout: { captured.out += $0 }, stderr: { captured.err += $0 }, version: "1.2.3",
                          makeEngine: engine)
  }

  func inputs(_ dir: URL, _ names: [String]) throws -> [String] {
    try names.map { name in
      let url = dir.appendingPathComponent(name)
      try WAVEncoder.encode(samples: tone(seconds: 1.5)).write(to: url)
      return url.path
    }
  }

  @Test func printsOneOrSeveralTranscripts() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = try inputs(dir, ["a.wav", "b.wav"])
    let engine = fakeEngine { _, _ in "hello" }
    var captured = Captured()
    #expect(command(captured) { engine }.transcribe([files[0]]) == 0)
    #expect(captured.out == "hello\n")
    #expect(captured.err.contains("Transcribing \(files[0]) (2s)..."))
    captured = Captured()
    #expect(command(captured) { engine }.transcribe(files + ["-q"]) == 0)
    #expect(captured.out == "==> \(files[0]) <==\nhello\n\n==> \(files[1]) <==\nhello\n")
    #expect(captured.err.isEmpty)
    captured = Captured()
    #expect(command(captured) { engine }.transcribe(files + ["-q", "--format", "json"]) == 0)
    let lines = captured.out.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines.allSatisfy { $0.hasPrefix("{\"file\": ") && $0.contains("\"engine\": \"swift_parakeet\"}") })
  }

  @Test func writesBesideAndToOutputWithoutOverwriting() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = try inputs(dir, ["a.wav", "b.wav"])
    try "keep\n".write(toFile: dir.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)
    let captured = Captured()
    let code = command(captured) { fakeEngine { _, _ in "fresh" } }.transcribe(files + ["--beside", "-q"])
    #expect(code == 1)
    #expect(captured.err.contains("khuluma: output exists (use --force to overwrite): \(dir.path)/a.txt"))
    #expect(try String(contentsOfFile: dir.appendingPathComponent("a.txt").path, encoding: .utf8) == "keep\n")
    #expect(try String(contentsOfFile: dir.appendingPathComponent("b.txt").path, encoding: .utf8) == "fresh\n")
    #expect(command(Captured()) { fakeEngine { _, _ in "forced" } }.transcribe(files + ["--beside", "--force", "-q"]) == 0)
    #expect(try String(contentsOfFile: dir.appendingPathComponent("a.txt").path, encoding: .utf8) == "forced\n")
    let out = dir.appendingPathComponent("o.json").path
    #expect(command(Captured()) { fakeEngine { _, _ in "j" } }.transcribe([files[0], "-o", out, "--format", "json", "-q"]) == 0)
    #expect(try String(contentsOfFile: out, encoding: .utf8).hasPrefix("{\"file\": "))
  }

  @Test func aFailedTranscriptionLeavesNoOutput() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = try inputs(dir, ["a.wav"])
    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
    let captured = Captured()
    #expect(command(captured) { fakeEngine { _, _ in throw Boom() } }.transcribe(files + ["--beside"]) == 1)
    #expect(captured.err.contains("khuluma: transcription failed: \(files[0]) (boom)"))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.wav"])
  }

  @Test func setupErrorsExitTwo() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = try inputs(dir, ["a.wav"])
    var captured = Captured()
    let noModel = command(captured) { throw FileTranscribeOptions.UsageError(FileEngineChoice.noModelMessage) }
    #expect(noModel.transcribe(files) == 2)
    #expect(captured.err == "khuluma: speech model not downloaded yet; open Khuluma once to download it\n")
    captured = Captured()
    #expect(command(captured) { fakeEngine { _, _ in "x" } }.transcribe([dir.appendingPathComponent("nope.wav").path]) == 2)
    #expect(captured.err.hasPrefix("khuluma: transcribe: not a readable file: "))
    captured = Captured()
    #expect(command(captured) { fakeEngine { _, _ in "x" } }.transcribe([dir.path]) == 2)
    captured = Captured()
    #expect(command(captured) { fakeEngine { _, _ in "x" } }.transcribe([]) == 2)
    #expect(captured.err.hasPrefix("usage: khuluma transcribe"))
  }

  @Test func otherCommands() {
    var captured = Captured()
    let cmd = { (c: Captured) in FileTranscribeCommand(stdout: { c.out += $0 }, stderr: { c.err += $0 }, version: "1.2.3",
                                                      makeEngine: { throw FileTranscribeOptions.UsageError("unused") }) }
    #expect(cmd(captured).main(["--version"]) == 0)
    #expect(captured.out == "khuluma 1.2.3\n")
    captured = Captured()
    #expect(cmd(captured).main(["help"]) == 0)
    #expect(captured.out.contains("transcribe <file>"))
    captured = Captured()
    #expect(cmd(captured).main(["dictate"]) == 2)
    #expect(captured.err == "khuluma: unknown command: dictate (run: khuluma help)\n")
    #expect(cmd(Captured()).main([]) == 2)
  }
}

struct QuickActionRunTests {
  @Test func writesBesideCopiesAndRefusesExisting() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("Voice memo.m4a")
    try writeAudio(a, seconds: 1.5, rate: 44_100, channels: 1, aac: true)
    var waits = 0
    let outcome = QuickActionRun.run([a.path], engine: { fakeEngine { _, _ in "hello" } }, waitWhileBusy: { waits += 1 },
                                     workDirectory: { try scratch() })
    #expect(outcome.failures.isEmpty)
    #expect(outcome.combined == "hello")
    #expect(outcome.notification == "Saved Voice memo.txt and copied it to the clipboard.")
    #expect(try String(contentsOfFile: dir.appendingPathComponent("Voice memo.txt").path, encoding: .utf8) == "hello\n")
    #expect(waits == 1)

    let again = QuickActionRun.run([a.path], engine: { fakeEngine { _, _ in "other" } }, waitWhileBusy: {},
                                   workDirectory: { try scratch() })
    #expect(again.combined.isEmpty)
    #expect(again.notification.hasPrefix("Transcription failed: output exists (use --force to overwrite): "))
    #expect(try String(contentsOfFile: dir.appendingPathComponent("Voice memo.txt").path, encoding: .utf8) == "hello\n")
  }

  @Test func severalFilesJoinForTheClipboard() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = try ["a.wav", "b.wav"].map { name -> String in
      let url = dir.appendingPathComponent(name)
      try WAVEncoder.encode(samples: tone(seconds: 1.2)).write(to: url)
      return url.path
    }
    let outcome = QuickActionRun.run(paths, engine: { fakeEngine { wav, _ in "t" } }, waitWhileBusy: {},
                                     workDirectory: { try scratch() })
    #expect(outcome.combined == "t\n\nt")
    #expect(outcome.notification == "Saved 2 transcripts and copied them to the clipboard.")
  }
}

/// The built helper, end to end, on a tiny WAV with no model.
struct BundledHelperTests {
  static var helper: URL? {
    // <scratch>/debug/KhulumaNativePackageTests.xctest/Contents/MacOS/… → <scratch>/debug/khuluma-cli
    var url = Bundle(for: Marker.self).bundleURL
    while url.pathExtension != "xctest" && url.path != "/" { url = url.deletingLastPathComponent() }
    let candidate = url.deletingLastPathComponent().appendingPathComponent("khuluma-cli")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
  }

  final class Marker {}

  func run(_ arguments: [String], environment: [String: String]) throws -> (Int32, String, String) {
    let process = Process()
    process.executableURL = try #require(Self.helper, "build the khuluma-cli product first")
    process.arguments = arguments
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  @Test func noModelAndBadArgumentsFailCleanly() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let support = dir.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    chmod(support.path, 0o700)
    let input = dir.appendingPathComponent("tiny.wav")
    try WAVEncoder.encode(samples: tone(seconds: 0.5)).write(to: input)
    let environment = ["HOME": dir.path, "TMPDIR": dir.path + "/",
                       "KHULUMA_SUPPORT_DIR": support.path,
                       "KHULUMA_DEFAULT_MODEL_DIR": dir.appendingPathComponent("no-model").path]
    let (code, out, err) = try run(["transcribe", input.path, "--beside"], environment: environment)
    #expect(code == 2)
    #expect(out.isEmpty)
    #expect(err == "khuluma: speech model not downloaded yet; open Khuluma once to download it\n")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tiny.txt").path))
    // Nothing reached the CLI's socket or config.
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".config").path))

    let dropped = try run(["transcribe", "--out-dir", dir.path, input.path], environment: environment)
    #expect(dropped.0 == 2 && dropped.2.hasPrefix("khuluma: transcribe: --out-dir is no longer supported"))
    let unknown = try run(["record"], environment: environment)
    #expect(unknown.0 == 2 && unknown.2 == "khuluma: unknown command: record (run: khuluma help)\n")
  }
}
