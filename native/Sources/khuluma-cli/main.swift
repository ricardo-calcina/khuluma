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

func makeEngine() throws -> FileTranscriber.Engine {
  let support = AppRuntimePaths.support
  var environment = SettingsEnvironment.current(appFolder: support)
  // FluidAudio's shared cache; an isolated run (KHULUMA_SUPPORT_DIR) may
  // point it elsewhere, so tests can check the no-model path.
  let override = ProcessInfo.processInfo.environment["KHULUMA_DEFAULT_MODEL_DIR"].flatMap { $0.isEmpty ? nil : $0 }
  environment.defaultModelPath = AppRuntimePaths.isolated && override != nil
    ? override : AsrModels.defaultCacheDirectory(for: .v3).path
  environment.modelAvailable = { ModelBundleCheck.isComplete($0, required: requiredFiles($1)) }
  // Read-only: the helper never writes settings (no last-good refresh).
  var store = SettingsStore(folder: support)
  store.readOnly = true
  let settings = store.load().settings
  guard let model = settings.resolvedModel(in: environment) else {
    throw FileTranscribeOptions.UsageError(FileEngineChoice.noModelMessage)
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
} catch {
  userError.write(Data("khuluma: \(error.localizedDescription)\n".utf8))
  exit(2)
}

let command = FileTranscribeCommand(
  stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
  stderr: { userError.write(Data($0.utf8)) },
  version: appVersion(),
  makeEngine: makeEngine,
  makeWorkDirectory: {
    let url = try FileTranscribeCommand.privateWorkDirectory()
    Cleanup.shared.set(url)
    return url
  })
exit(command.main(Array(CommandLine.arguments.dropFirst())))
