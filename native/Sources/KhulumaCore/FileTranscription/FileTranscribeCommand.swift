import Foundation

/// The bundled `khuluma` helper's commands: `transcribe`, `--version`,
/// `help`. Everything that touches the outside world is injected, so the
/// whole command runs in tests.
public struct FileTranscribeCommand {
  public var stdout: (String) -> Void
  public var stderr: (String) -> Void
  public var version: String
  /// The engine for this run, chosen once up front, or a `UsageError`
  /// (no model: exit 2 before any file is touched, like the CLI).
  public var makeEngine: () throws -> FileTranscriber.Engine
  /// A fresh private folder for the decoded WAVs; removed after the run.
  public var makeWorkDirectory: () throws -> URL
  public var transcriber = FileTranscriber()

  public init(stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void, version: String,
              makeEngine: @escaping () throws -> FileTranscriber.Engine,
              makeWorkDirectory: @escaping () throws -> URL = FileTranscribeCommand.privateWorkDirectory) {
    self.stdout = stdout
    self.stderr = stderr
    self.version = version
    self.makeEngine = makeEngine
    self.makeWorkDirectory = makeWorkDirectory
  }

  public static let topUsage = """
    usage: khuluma <command>

    Commands:
      transcribe <file>...   transcribe audio files (khuluma transcribe --help)
      help                   show this help
      --version              show the version

    """

  /// `arguments` without the program name; returns the exit code.
  public func main(_ arguments: [String]) -> Int32 {
    guard let command = arguments.first else {
      stderr(Self.topUsage)
      return 2
    }
    switch command {
    case "transcribe": return transcribe(Array(arguments.dropFirst()))
    case "--version", "-V", "version":
      stdout("khuluma \(version)\n")
      return 0
    case "help", "-h", "--help":
      stdout(Self.topUsage)
      return 0
    default:
      stderr("khuluma: unknown command: \(command) (run: khuluma help)\n")
      return 2
    }
  }

  public func transcribe(_ arguments: [String]) -> Int32 {
    let options: FileTranscribeOptions
    do {
      switch try FileTranscribeOptions.parse(arguments) {
      case .help:
        stdout(FileTranscribeOptions.usage)
        return 0
      case .run(let parsed): options = parsed
      }
    } catch let error as FileTranscribeOptions.UsageError {
      if error.showUsage { stderr(FileTranscribeOptions.usage) } else { stderr("khuluma: \(error.message)\n") }
      return error.exitCode
    } catch {
      stderr("khuluma: \(error.localizedDescription)\n")
      return 2
    }
    return run(options)
  }

  public func run(_ options: FileTranscribeOptions) -> Int32 {
    func log(_ line: String) { if !options.quiet { stderr(line + "\n") } }
    func fail(_ message: String) { stderr("khuluma: \(message)\n") }

    for input in options.inputs where !FileManager.default.isReadableFile(atPath: input) || isDirectory(input) {
      fail("transcribe: not a readable file: \(input)")
      return 2
    }
    let engine: FileTranscriber.Engine
    do {
      engine = try makeEngine()
    } catch let error as FileTranscribeOptions.UsageError {
      fail(error.message)
      return error.exitCode
    } catch {
      fail(error.localizedDescription)
      return 2
    }
    let work: URL
    do {
      work = try makeWorkDirectory()
    } catch {
      fail("transcribe: cannot create a temporary directory")
      return 2
    }
    defer { try? FileManager.default.removeItem(at: work) }

    let ext = options.format.rawValue
    let total = options.inputs.count
    var failures = 0
    for (offset, input) in options.inputs.enumerated() {
      let index = offset + 1
      let destination = TranscriptOutput.destination(for: input, output: options.output, beside: options.beside, ext: ext)
      if let destination {
        do {
          try TranscriptOutput.precheck(destination: destination, input: input, force: options.force)
        } catch {
          fail(error.localizedDescription)
          failures += 1
          continue
        }
      }
      var transcriber = self.transcriber
      transcriber.onDecoded = { durationMs in
        let what = "Transcribing \(input) (\(FileTranscriber.formatDuration(durationMs)))..."
        log(total > 1 ? "[\(index)/\(total)] \(what)" : what)
      }
      let transcript: FileTranscriber.Transcript
      do {
        transcript = try transcriber.transcribe(URL(fileURLWithPath: input), label: input, workDirectory: work,
                                                engine: engine)
      } catch {
        fail(error.localizedDescription)
        failures += 1
        continue
      }
      log("Done in \(FileTranscriber.formatDuration(transcript.processingMs)).")
      let record = options.format == .json ? TranscriptOutput.jsonLine(file: input, transcript: transcript) : transcript.text
      if let destination {
        do {
          try TranscriptOutput.write(record, to: destination, force: options.force)
          log("Wrote \(destination)")
        } catch {
          fail(error.localizedDescription)
          failures += 1
        }
      } else if options.format == .txt && total > 1 {
        stdout((index > 1 ? "\n" : "") + "==> \(input) <==\n\(record)\n")
      } else {
        stdout(record + "\n")
      }
    }
    return failures == 0 ? 0 : 1
  }

  private func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
  }

  /// `$TMPDIR/khuluma-transcribe.XXXXXX`, 0700.
  public static func privateWorkDirectory() throws -> URL {
    var template = Array((NSTemporaryDirectory() as NSString)
      .appendingPathComponent("khuluma-transcribe.XXXXXX").utf8CString)
    guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else {
      throw CocoaError(.fileWriteUnknown)
    }
    return URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
  }
}
