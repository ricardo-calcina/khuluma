import Darwin
import FluidAudio
import Foundation
import KhulumaCore
import KhulumaDaemonKit

// `khuluma`, bundled as Khuluma.app/Contents/Helpers/khuluma: file
// transcription without the CLI. Uses the app's daemon on the app's socket
// when it holds the model, else loads the model in this process. Never the
// CLI's daemon, socket or command.

/// The work folder, for the interrupt handler.
final class Cleanup: @unchecked Sendable {
  static let shared = Cleanup()
  private let lock = NSLock()
  private var directory: URL?
  func set(_ url: URL) { lock.withLock { directory = url } }
  func run() {
    PendingOutputs.shared.removeAll()
    if let directory = lock.withLock({ directory }) { try? FileManager.default.removeItem(at: directory) }
  }
}

var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM, SIGHUP] {
  signal(number, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
  source.setEventHandler {
    Cleanup.shared.run()
    exit(130)
  }
  source.resume()
  signalSources.append(source)
}

func appVersion() -> String {
  // Contents/Helpers/khuluma → Contents/Info.plist.
  let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
  if let info = NSDictionary(contentsOf: plist), let version = info["CFBundleShortVersionString"] as? String {
    return version
  }
  return "dev"
}

func requiredFiles(_ version: String) -> Set<String> {
  (version == "v2" ? ModelNames.ASR.requiredModels : ModelNames.ASR.requiredModelsV3(precision: .int8))
    .union([ModelNames.ASR.vocabularyFile])
}

/// Blocks on the in-process engine (this is a command-line tool).
final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
  let box = ResultBox<T>()
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
    done.signal()
  }
  done.wait()
  return try box.result!.get()
}

func inProcessEngine(path: String, version: String) -> FileTranscriber.Engine {
  let engine = ASREngine()
  let modelURL = URL(fileURLWithPath: path, isDirectory: true)
  return FileTranscriber.Engine(name: DaemonInfo.engineName, model: modelURL.lastPathComponent) { wav, _, _ in
    try runBlocking { try await engine.transcribe(audioURL: wav, modelURL: modelURL, modelVersion: version).text }
  }
}

/// Live-transcription simulation (`KHULUMA_LIVE_SIMULATE=1`, experiment only):
/// one in-process engine, the file cut at pauses with `PauseSegmenter`, each
/// segment through the normal `NativeTranscriber` path, joined; the whole
/// file also transcribed for comparison into `<input>.whole.txt`.
final class LiveSim: @unchecked Sendable {
  static let shared = LiveSim()
  var on = false
  /// KHULUMA_LIVE_NO_SEGMENT_TAIL=1: non-final segments skip tail rescue.
  var noSegmentTail = false
  var config = PauseSegmenter.Config()
  var engine: ASREngine?
  var modelURL: URL?
  var modelVersion = ""
  var warmed = false

  // Per-file figures for the `live:` stderr line.
  var input = ""
  var audioMs = 0
  var segments = 0
  var forced = 0
  var segMs: [Int] = []
  var segAsrMs: [Int] = []
  var wholeAsrMs = 0
  var inlineSpans: [[Int]]?

  /// `Transcribing <input> (<dur>)...` (or `[i/n] ` prefixed) resets the
  /// per-file figures and learns the input path for `.whole.txt`.
  func note(_ line: String) {
    guard let range = line.range(of: "Transcribing ") else { return }
    let rest = line[range.upperBound...]
    if let open = rest.range(of: " (", options: .backwards) {
      input = String(rest[..<open.lowerBound])
    }
    audioMs = 0; segments = 0; forced = 0
    segMs = []; segAsrMs = []; wholeAsrMs = 0
  }

  func line() -> String {
    let seg = segMs.map(String.init).joined(separator: ",")
    let asr = segAsrMs.map(String.init).joined(separator: ",")
    return "live: audio_ms=\(audioMs) segments=\(segments) forced=\(forced)"
      + " seg_ms=\(seg) seg_asr_ms=\(asr)"
      + " last_asr_ms=\(segAsrMs.last ?? 0) whole_asr_ms=\(wholeAsrMs)"
  }

  /// 16-bit PCM RIFF → Float samples: finds the "data" chunk and reads LE.
  static func wavFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    var offset = 12
    while offset + 8 <= data.count {
      let tag = String(decoding: data[offset..<offset + 4], as: UTF8.self)
      let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8
        | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
      if tag == "data" {
        let end = min(offset + 8 + size, data.count)
        var samples: [Float] = []
        samples.reserveCapacity((end - offset - 8) / 2)
        var index = offset + 8
        while index + 1 < end {
          let pcm = Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)
          samples.append(Float(pcm) / 32768)
          index += 2
        }
        return samples
      }
      offset += 8 + size + (size & 1)
    }
    return []
  }

  private static func wallMs(_ start: ContinuousClock.Instant) -> Int {
    let elapsed = start.duration(to: ContinuousClock.now)
    return Int(elapsed.components.seconds * 1000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  /// One decoded WAV through the whole + segmented paths; returns the LIVE
  /// joined text (the file's normal output is this text).
  func transcribeSimulated(wav: URL) throws -> String {
    guard let engine, let modelURL else { throw FileTranscriber.Failure("live simulation is not set up") }
    let samples = try Self.wavFloats(wav)
    audioMs = samples.count * 1000 / 16_000
    if !warmed {
      warmed = true
      _ = try runBlocking { try await engine.warmup(modelURL: modelURL, modelVersion: self.modelVersion) }
    }
    let transcriber = NativeTranscriber(settings: TranscriptionSettings(socketPath: "", modelPath: nil))
    // KHULUMA_LIVE_NO_SEGMENT_TAIL: finished segments skip the tail pass;
    // the last open one and WHOLE keep it.
    var noTailSettings = TranscriptionSettings(socketPath: "", modelPath: nil)
    noTailSettings.tailRescue = false
    let noTailTranscriber = NativeTranscriber(settings: noTailSettings)
    let pass: NativeTranscriber.TranscribePass = { url, flow in
      let result = try runBlocking {
        try await engine.transcribe(audioURL: url, modelURL: modelURL, modelVersion: self.modelVersion)
      }
      if flow == "inline" { self.inlineSpans = result.wordSpansMs }
      return .init(text: result.text, daemonMs: result.durationMs, wordSpansMs: result.wordSpansMs)
    }

    // WHOLE: the take as one transcription, for comparison.
    var mark = ContinuousClock.now
    let whole = try transcriber.transcribeTimed(samples: samples, passes: pass)
    wholeAsrMs = Self.wallMs(mark)
    try? (whole.transcript + "\n").write(
      toFile: input + ".whole.txt", atomically: true, encoding: .utf8)

    // LIVE: feed the audio in 250 ms chunks, cut at pauses, transcribe each
    // finished segment and the last open one, join.
    var segmenter = PauseSegmenter(config: config)
    var cuts: [PauseSegmenter.Cut] = []
    var offset = 0
    while offset < samples.count {
      cuts.append(contentsOf: segmenter.feed(Array(samples[offset..<min(offset + 4_000, samples.count)])))
      offset += 4_000
    }
    forced = cuts.filter { $0.forced }.count
    var bounds: [(Int, Int)] = []
    var start = 0
    for cut in cuts {
      bounds.append((start, cut.sample))
      start = cut.sample
    }
    bounds.append((start, samples.count))
    segments = bounds.count
    var parts: [LiveTranscript.Part] = []
    for (index, (from, to)) in bounds.enumerated() {
      inlineSpans = nil
      mark = ContinuousClock.now
      let segmentTranscriber = noSegmentTail && index < bounds.count - 1 ? noTailTranscriber : transcriber
      let result = try segmentTranscriber.transcribeTimed(samples: Array(samples[from..<to]), passes: pass)
      segMs.append((to - from) * 1000 / 16_000)
      segAsrMs.append(Self.wallMs(mark))
      parts.append(.init(text: result.transcript, wordSpansMs: inlineSpans, startMs: from * 1000 / 16_000))
    }
    return LiveTranscript.join(parts).text
  }
}

/// The simulation always runs the in-process engine (never the daemon).
func liveEngine(path: String, version: String) -> FileTranscriber.Engine {
  let live = LiveSim.shared
  let engine = ASREngine()
  live.engine = engine
  live.modelURL = URL(fileURLWithPath: path, isDirectory: true)
  live.modelVersion = version
  return FileTranscriber.Engine(name: DaemonInfo.engineName, model: live.modelURL!.lastPathComponent) { wav, _, _ in
    try live.transcribeSimulated(wav: wav)
  }
}

func makeEngine() throws -> FileTranscriber.Engine {
  let support = AppRuntimePaths.support
  var environment = SettingsEnvironment.current(appFolder: support)
  // The same default model folder as the app: FluidAudio's shared cache,
  // or a private one in isolated runs.
  environment.defaultModelPath = AppRuntimePaths.defaultModelDirectory(
    environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser,
    sharedCache: AsrModels.defaultCacheDirectory(for: .v3)).path
  environment.modelAvailable = { ModelBundleCheck.isComplete($0, required: requiredFiles($1)) }
  // Read-only: the helper never writes settings (no last-good refresh).
  var store = SettingsStore(folder: support)
  store.readOnly = true
  let settings = store.load().settings
  guard let model = settings.resolvedModel(in: environment) else {
    throw FileTranscribeOptions.UsageError(FileEngineChoice.noModelMessage)
  }
  if LiveSim.shared.on { return liveEngine(path: model.path, version: model.version) }
  let socket = DaemonSocketPath.prepared(support: support)
  let status = socket.issue == nil ? DaemonClient(socketPath: socket.resolved.path).status(timeout: 1) : nil
  let local = inProcessEngine(path: model.path, version: model.version)
  switch FileEngineChoice.choose(model: model, daemon: status) {
  case .noModel: throw FileTranscribeOptions.UsageError(FileEngineChoice.noModelMessage)
  case .inProcess: return local
  case .daemon:
    let daemon = FileTranscriber.Engine.daemon(
      socketPath: socket.resolved.path, modelPath: model.path, modelVersion: model.version,
      language: settings.transcription.language)
    // The app quit meanwhile: nothing was sent, so load the model here.
    return FileTranscriber.Engine(name: daemon.name, model: daemon.model, chunksLongFiles: true) { wav, flow, timeout in
      do {
        return try daemon.transcribe(wav, flow, timeout)
      } catch DaemonClient.ClientError.unreachable {
        return try local.transcribe(wav, flow, timeout)
      }
    }
  }
}

// FluidAudio writes its own log lines to stderr; only ours reach the user
// (and -q silences those too).
let userError = FileHandle(fileDescriptor: dup(STDERR_FILENO), closeOnDealloc: false)
let devNull = open("/dev/null", O_WRONLY)
if devNull >= 0 { dup2(devNull, STDERR_FILENO); close(devNull) }

// The app's isolation rules, before any settings or socket is touched: a
// partial or unsafe override is refused instead of mixing in daily state.
do {
  try AppRuntimePaths.prepareIsolation()
} catch {
  userError.write(Data("khuluma: \(error.localizedDescription)\n".utf8))
  exit(2)
}

// Live-transcription simulation (experiment): env tuning knobs, parsed as
// ints when present.
let liveEnvironment = ProcessInfo.processInfo.environment
if liveEnvironment["KHULUMA_LIVE_SIMULATE"] == "1" {
  LiveSim.shared.on = true
  if let ms = liveEnvironment["KHULUMA_LIVE_MIN_MS"].flatMap(Int.init) { LiveSim.shared.config.minSegmentMs = ms }
  if let ms = liveEnvironment["KHULUMA_LIVE_MAX_MS"].flatMap(Int.init) { LiveSim.shared.config.maxSegmentMs = ms }
  if let ms = liveEnvironment["KHULUMA_LIVE_PAUSE_MS"].flatMap(Int.init) { LiveSim.shared.config.pauseMs = ms }
  if liveEnvironment["KHULUMA_LIVE_NO_SEGMENT_TAIL"] == "1" { LiveSim.shared.noSegmentTail = true }
}

var command = FileTranscribeCommand(
  stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
  stderr: { line in
    if LiveSim.shared.on { LiveSim.shared.note(line) }
    userError.write(Data(line.utf8))
    if LiveSim.shared.on, line.hasPrefix("Done in ") {
      userError.write(Data((LiveSim.shared.line() + "\n").utf8))
    }
  },
  version: appVersion(),
  makeEngine: makeEngine,
  makeWorkDirectory: {
    let url = try FileTranscribeCommand.privateWorkDirectory()
    Cleanup.shared.set(url)
    return url
  })
// The simulation does its own segmentation; a second "file-tail" pass per
// file would double-transcribe the last segment.
if LiveSim.shared.on { command.transcriber.tailRescueMinMs = .max }
exit(command.main(Array(CommandLine.arguments.dropFirst())))
