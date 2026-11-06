import Foundation

/// `khuluma transcribe` arguments: the CLI's keep-list (`-q`, `--format`,
/// `-o`, `--beside`, `--force`, several files). The CLI's `-c`, `--out-dir`,
/// stdin `-` and `--no-tail-rescue` are refused with a clear error.
public struct FileTranscribeOptions: Equatable, Sendable {
  public enum Format: String, Sendable { case txt, json }

  public var inputs: [String] = []
  public var output: String?
  public var beside = false
  public var force = false
  public var format: Format = .txt
  public var quiet = false

  public init() {}

  /// Why the arguments can't run, as the CLI's `die` says it: `message` is
  /// what follows `khuluma: `, `exitCode` 2 as `die` exits.
  public struct UsageError: Error, Equatable, Sendable {
    public let message: String
    public let exitCode: Int32
    /// Print the usage text to stderr (no inputs at all).
    public let showUsage: Bool

    public init(_ message: String, exitCode: Int32 = 2, showUsage: Bool = false) {
      self.message = message
      self.exitCode = exitCode
      self.showUsage = showUsage
    }
  }

  public enum Parsed: Equatable, Sendable {
    case help
    case run(FileTranscribeOptions)
  }

  static let dropped: [String: String] = [
    "-c": "-c/--clipboard is no longer supported; pipe to pbcopy instead",
    "--clipboard": "-c/--clipboard is no longer supported; pipe to pbcopy instead",
    "--out-dir": "--out-dir is no longer supported; use --beside or -o",
    "--no-tail-rescue": "--no-tail-rescue is no longer supported",
    "-": "reading audio from stdin (-) is no longer supported; pass a file path",
  ]

  /// Arguments after `transcribe`.
  public static func parse(_ arguments: [String]) throws -> Parsed {
    var options = FileTranscribeOptions()
    var index = 0
    func value(_ flag: String, _ what: String) throws -> String {
      guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
        throw UsageError("transcribe: \(flag) requires \(what)")
      }
      index += 1
      return arguments[index]
    }
    while index < arguments.count {
      let argument = arguments[index]
      let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
      if let reason = dropped[name], argument.hasPrefix("-") {
        throw UsageError("transcribe: \(reason)")
      }
      switch argument {
      case "-h", "--help": return .help
      case "-o", "--output": options.output = try value(argument, "a file path")
      case "--beside": options.beside = true
      case "--force": options.force = true
      case "-q", "--quiet": options.quiet = true
      case "--format":
        guard index + 1 < arguments.count else { throw UsageError("transcribe: --format requires txt or json") }
        index += 1
        options.format = try format(arguments[index])
      case "--":
        options.inputs += arguments[(index + 1)...]
        index = arguments.count
        continue
      default:
        if argument.hasPrefix("--output=") {
          options.output = String(argument.dropFirst("--output=".count))
        } else if argument.hasPrefix("--format=") {
          options.format = try format(String(argument.dropFirst("--format=".count)))
        } else if argument.hasPrefix("-") {
          throw UsageError("transcribe: unknown option: \(argument) (run: khuluma transcribe --help)")
        } else {
          options.inputs.append(argument)
        }
      }
      index += 1
    }
    if options.inputs.contains("-") { throw UsageError("transcribe: \(dropped["-"]!)") }
    guard !options.inputs.isEmpty else { throw UsageError("", exitCode: 2, showUsage: true) }
    if options.output?.isEmpty == true { throw UsageError("transcribe: -o requires a file path") }
    if options.output != nil && options.beside { throw UsageError("transcribe: use only one of -o, --beside") }
    if options.output != nil && options.inputs.count > 1 {
      throw UsageError("transcribe: -o takes a single input; use --beside for several")
    }
    return .run(options)
  }

  private static func format(_ raw: String) throws -> Format {
    guard let format = Format(rawValue: raw) else { throw UsageError("transcribe: --format must be txt or json") }
    return format
  }

  public static let usage = """
    usage: khuluma transcribe <file>... [options]

    Transcribe audio or video files (m4a, mp3, wav, aac, flac, mp4, mov) with
    the local Parakeet model and print the raw transcript.

    Output (default: stdout):
      -o, --output FILE   write to FILE (single input only)
      --beside            write <name>.txt (or .json) next to each input
      --force             overwrite existing output files

    Format:
      --format txt|json   txt (default) or one JSON object per input:
                          {file, text, audio_duration_ms, processing_ms, model, engine}

    Other:
      -q, --quiet         no progress messages on stderr

    Uses Khuluma's own speech model; while the app runs, its daemon does the
    work and dictation waits until a long file finishes.

    """
}
