import Foundation
import KhulumaCore

/// Runs the installed `tmux-whisper` CLI, which owns transcription, cleanup,
/// history and usage accounting.
struct CLIBridge {
  enum BridgeError: Error, LocalizedError {
    case notInstalled
    case failed(String)
    case timedOut(Double)
    case badOutput(String)

    var errorDescription: String? {
      switch self {
      case .notInstalled: return "tmux-whisper CLI not found (~/.local/bin or Homebrew)"
      case .failed(let message): return message
      case .timedOut(let seconds): return "tmux-whisper did not answer within \(Int(seconds))s"
      case .badOutput(let detail): return "unexpected tmux-whisper output: \(detail)"
      }
    }
  }

  let binary: URL

  static func locate() -> CLIBridge? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      ProcessInfo.processInfo.environment["KHULUMA_CLI"],
      "\(home)/.local/bin/tmux-whisper",
      "/opt/homebrew/bin/tmux-whisper",
      "/usr/local/bin/tmux-whisper",
    ].compactMap { $0 }
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return CLIBridge(binary: URL(fileURLWithPath: path))
    }
    return nil
  }

  /// The settings, checked first against Khuluma's app contract: throws
  /// `AppContract.Mismatch` for a CLI that isn't the one Khuluma was built with.
  func appConfig() throws -> AppConfig {
    let data = try run(["app-config", "--json"], timeout: 15)
    do {
      return try AppContract.decodeAppConfig(data)
    } catch let mismatch as AppContract.Mismatch {
      throw mismatch
    } catch {
      throw BridgeError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
    }
  }

  /// `--defer-usage`: the CLI doesn't count the take; the caller records
  /// usage once it has delivered.
  func process(wav: URL, app: String?, recordMs: Int, startupMs: Int, startedAtEpochMs: Int) throws -> ProcessResult {
    var args = ["inline", "process", wav.path, "--json", "--defer-usage",
                "--record-ms", String(recordMs), "--startup-ms", String(startupMs),
                "--started-at-ms", String(startedAtEpochMs)]
    if let app, !app.isEmpty {
      args += ["--app", app]
    }
    // Long recordings take longer to transcribe; stay generous.
    let timeout = max(120, Double(recordMs) / 1000 * 1.5 + 60)
    let data = try run(args, timeout: timeout)
    do {
      return try JSONDecoder().decode(ProcessResult.self, from: data)
    } catch {
      throw BridgeError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
    }
  }

  /// `warmup --json`: starts the daemon if needed (under the CLI's
  /// lifecycle lock) and loads the model, reporting ready/warming/unavailable.
  func warmup() throws -> WarmupReport {
    let data = try run(["warmup", "--json"], timeout: 120)
    do {
      return try JSONDecoder().decode(WarmupReport.self, from: data)
    } catch {
      throw BridgeError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
    }
  }

  /// Persists a native take (history, bench, usage) with the CLI's writers.
  func record(_ take: TakeRecord) throws -> RecordResult {
    let data = try run(["inline", "record", "--json"], timeout: 30, input: try JSONEncoder().encode(take))
    do {
      return try JSONDecoder().decode(RecordResult.self, from: data)
    } catch {
      throw BridgeError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
    }
  }

  /// `usage --json --days all`: lifetime totals and per-day buckets.
  /// Counts and durations only: no transcript text is ever in it.
  func usage() throws -> UsageReport {
    let data = try run(["usage", "--json", "--days", "all"], timeout: 10)
    do {
      return try JSONDecoder().decode(UsageReport.self, from: data)
    } catch {
      throw BridgeError.badOutput("usage report did not decode")
    }
  }

  private func run(_ arguments: [String], timeout: Double, input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [binary.path] + arguments
    process.environment = CLIEnvironment.forCLI(
      base: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser.path)

    // Temp files, not pipes: a child left running can't block us on a full pipe.
    let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-cli-\(UUID().uuidString).out")
    let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-cli-\(UUID().uuidString).err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: outURL)
      try? FileManager.default.removeItem(at: errURL)
    }
    let outHandle = try FileHandle(forWritingTo: outURL)
    let errHandle = try FileHandle(forWritingTo: errURL)
    process.standardOutput = outHandle
    process.standardError = errHandle
    var inURL: URL?
    if let input {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("khuluma-cli-\(UUID().uuidString).in")
      guard FileManager.default.createFile(atPath: url.path, contents: input, attributes: [.posixPermissions: 0o600]),
            let handle = FileHandle(forReadingAtPath: url.path) else {
        throw BridgeError.failed("cannot stage input for tmux-whisper")
      }
      inURL = url
      process.standardInput = handle
    } else {
      process.standardInput = FileHandle.nullDevice
    }
    defer { if let inURL { try? FileManager.default.removeItem(at: inURL) } }

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      // A wedged CLI that ignores SIGTERM must not outlive the request.
      if finished.wait(timeout: .now() + 3) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
      }
      throw BridgeError.timedOut(timeout)
    }
    try? outHandle.close()
    try? errHandle.close()

    let output = (try? Data(contentsOf: outURL)) ?? Data()
    guard process.terminationStatus == 0 else {
      let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw BridgeError.failed(stderr.isEmpty ? "tmux-whisper exited \(process.terminationStatus)" : stderr)
    }
    return output
  }
}
