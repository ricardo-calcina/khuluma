import Foundation
import KhulumaDaemonKit

enum CLIError: Error, LocalizedError {
  case usage(String)

  var errorDescription: String? {
    switch self {
    case .usage(let message):
      return message
    }
  }
}

@main
enum KhulumaDaemonMain {
  static func main() async {
    do {
      try await run()
    } catch {
      fputs("khulumad: \(error.localizedDescription)\n", stderr)
      exit(2)
    }
  }

  private static func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "help"
    if !arguments.isEmpty {
      arguments.removeFirst()
    }

    switch command {
    case "serve":
      let (socketPath, exitWithParent) = try parseServe(arguments)
      let server = UnixSocketServer(socketPath: socketPath, handler: TranscriptionService())
      let signalSources = installShutdownHandlers(server: server)
      defer { signalSources.forEach { $0.cancel() } }
      let parentWatch = exitWithParent ? watchParent(server: server) : nil
      defer { parentWatch?.cancel() }
      try await server.run()
    case "version", "--version":
      print("khulumad \(DaemonInfo.daemonVersion)")
    case "help", "-h", "--help":
      printUsage()
    default:
      throw CLIError.usage("unknown command: \(command)")
    }
  }

  /// Stop cleanly on SIGTERM/SIGINT: release the socket, drain, then exit.
  private static func installShutdownHandlers(server: UnixSocketServer) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { signalNumber in
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler {
        // Finish requests already accepted (e.g. a long file transcription)
        // before exiting; the socket is released immediately for a successor.
        server.stop(drainTimeout: 900)
        exit(0)
      }
      source.resume()
      return source
    }
  }

  /// `--exit-with-parent` (the app passes it): stop when the process that
  /// started us exits, so a crashed or killed app never leaves an orphan
  /// holding the socket and the model. A kqueue NOTE_EXIT on the parent pid,
  /// registered while it is alive; a parent already gone (ppid 1) means exit
  /// now, which also covers it dying just before the watch was registered.
  private static func watchParent(server: UnixSocketServer) -> DispatchSourceProcess? {
    let parent = getppid()
    let stop = {
      fputs("khulumad: parent process exited; stopping\n", stderr)
      server.stop(drainTimeout: 5)
      exit(0)
    }
    guard parent > 1 else { stop(); return nil }
    let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    source.setEventHandler { stop() }
    source.resume()
    if getppid() != parent { stop() }
    return source
  }

  private static func parseServe(_ arguments: [String]) throws -> (socket: String, exitWithParent: Bool) {
    var iterator = arguments.makeIterator()
    var socketPath: String?
    var exitWithParent = false

    while let argument = iterator.next() {
      switch argument {
      case "--exit-with-parent":
        exitWithParent = true
      case "--socket":
        socketPath = iterator.next()
      default:
        throw CLIError.usage("unknown argument: \(argument)")
      }
    }

    guard let socketPath, !socketPath.isEmpty else {
      throw CLIError.usage("serve requires --socket <path>")
    }
    return (socketPath, exitWithParent)
  }

  private static func printUsage() {
    print(
      """
      khulumad: persistent local transcription daemon for Khuluma.

      Usage:
        khulumad serve --socket /path/to/khulumad.sock [--exit-with-parent]
        khulumad version
      """
    )
  }
}
