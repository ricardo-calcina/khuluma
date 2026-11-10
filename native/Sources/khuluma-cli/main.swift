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

func inProcessEngine(path: String, version: String, boost: [EngineBoostTerm] = [],
                     minSimilarity: Float? = nil, stats: BoostStats? = nil) -> FileTranscriber.Engine {
  let engine = ASREngine()
  let modelURL = URL(fileURLWithPath: path, isDirectory: true)
  return FileTranscriber.Engine(name: DaemonInfo.engineName, model: modelURL.lastPathComponent) { wav, _, _ in
    let result = try runBlocking {
      try await engine.transcribe(audioURL: wav, modelURL: modelURL, modelVersion: version,
                                  boost: boost, minSimilarity: minSimilarity)
    }
    stats?.record(result)
    return result.text
  }
}

/// Per-file boosting figures for the `boost:` stderr line (experiment).
final class BoostStats: @unchecked Sendable {
  private let lock = NSLock()
  /// The decoded terms (empty = the experiment is off).
  private(set) var list: [EngineBoostTerm] = []
  /// KHULUMA_BOOST_MIN_SIMILARITY as parsed (nil = FluidAudio default).
  private(set) var minSimilarity: Float?
  private var terms = 0
  private var aliasesLabel = "on"
  private var minSimLabel = "default"
  private var calls = 0
  private var ms = 0
  private var loadMs: Int?
  private var replacements = 0
  private var asrMs = 0

  func adopt(_ terms: [EngineBoostTerm], aliasesOff: Bool, minSimilarity: Float?) {
    list = terms
    self.terms = terms.count
    self.minSimilarity = minSimilarity
    aliasesLabel = aliasesOff ? "off" : "on"
    minSimLabel = minSimilarity.map { String(format: "%g", $0) } ?? "default"
  }

  func record(_ result: TranscriptionResult) {
    lock.withLock {
      calls += 1
      ms += result.boostMs ?? 0
      asrMs += result.durationMs
      replacements += result.boostReplacements ?? 0
      if loadMs == nil { loadMs = result.boostLoadMs }
    }
  }

  /// A new file is starting.
  func reset() {
    lock.withLock {
      calls = 0; ms = 0; loadMs = nil; replacements = 0; asrMs = 0
    }
  }

  /// The line to print after the file finished, if any calls ran.
  func line() -> String? {
    lock.withLock {
      guard calls > 0 else { return nil }
      return "boost: terms=\(terms) aliases=\(aliasesLabel) min_sim=\(minSimLabel) ms=\(ms) load_ms=\(loadMs ?? 0) replacements=\(replacements) asr_ms=\(asrMs)"
    }
  }
}

/// Experimental vocabulary boost: `KHULUMA_BOOST_VOCABULARY=<vocabulary.json>`
/// maps the Brands section through `BoostTerms` and forces the in-process
/// engine (never the daemon).
let boostStats = BoostStats()
func loadBoostTerms() throws {
  guard let path = ProcessInfo.processInfo.environment["KHULUMA_BOOST_VOCABULARY"], !path.isEmpty else { return }
  let environment = ProcessInfo.processInfo.environment
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let sheet = try VocabularySheet.decode(data)
  // KHULUMA_BOOST_NO_ALIASES=1 strips heard-forms; KHULUMA_BOOST_MIN_SIMILARITY
  // raises the vocabulary-level similarity floor (experiment knobs).
  let aliasesOff = environment["KHULUMA_BOOST_NO_ALIASES"] == "1"
  let minSimilarity = environment["KHULUMA_BOOST_MIN_SIMILARITY"].flatMap { Float($0) }
  boostStats.adopt(
    BoostTerms.from(sheet).map {
      EngineBoostTerm(text: $0.text, aliases: aliasesOff ? [] : $0.aliases)
    },
    aliasesOff: aliasesOff, minSimilarity: minSimilarity)
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
  // Boost experiment: always the in-process engine, never the daemon.
  if !boostStats.list.isEmpty {
    return inProcessEngine(path: model.path, version: model.version, boost: boostStats.list,
                           minSimilarity: boostStats.minSimilarity, stats: boostStats)
  }
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
  try loadBoostTerms()
} catch {
  userError.write(Data("khuluma: \(error.localizedDescription)\n".utf8))
  exit(2)
}

let command = FileTranscribeCommand(
  stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
  stderr: { line in
    // The boost line lands after each file's "Done in …": accumulated over
    // however many engine calls that file needed (chunks, tail pass).
    if !boostStats.list.isEmpty, line.contains("Transcribing ") { boostStats.reset() }
    userError.write(Data(line.utf8))
    if !boostStats.list.isEmpty, line.hasPrefix("Done in "), let report = boostStats.line() {
      userError.write(Data((report + "\n").utf8))
    }
  },
  version: appVersion(),
  makeEngine: makeEngine,
  makeWorkDirectory: {
    let url = try FileTranscribeCommand.privateWorkDirectory()
    Cleanup.shared.set(url)
    return url
  })
exit(command.main(Array(CommandLine.arguments.dropFirst())))
