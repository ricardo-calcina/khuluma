import Foundation

/// The Quick Action's work, as the CLI's Finder handler did it
/// (`khuluma transcribe --beside --clipboard`): `<name>.txt` beside each file,
/// never over an existing one (then `<name>-2.txt`, `-3`, ... the first
/// free name, claimed atomically; Ricardo's call, 2026-11-06), the
/// transcripts joined for the clipboard, and one notification line.
public enum QuickActionRun {
  public struct Outcome: Equatable, Sendable {
    /// Successful transcripts, blank-line separated (the CLI's clipboard).
    public let combined: String
    public let written: [String]
    /// `khuluma: `-style reasons, one per failed file.
    public let failures: [String]
    public let notification: String
  }

  public static func run(_ inputs: [String], engine: () throws -> FileTranscriber.Engine,
                         waitWhileBusy: @escaping () -> Void, workDirectory: () throws -> URL,
                         transcriber base: FileTranscriber = FileTranscriber()) -> Outcome {
    var transcriber = base
    // A take recording or in flight goes first: checked right before every
    // daemon request (long files go in chunks).
    transcriber.beforeRequest = waitWhileBusy
    return run(inputs, workDirectory: workDirectory) { input, work in
      try transcriber.transcribe(input, label: input.path, workDirectory: work, engine: engine()).text
    }
  }

  /// Shared output handling for local transcripts and original media uploaded to the cloud.
  public static func run(_ inputs: [String], workDirectory: () throws -> URL,
                         transcribe: (_ input: URL, _ workDirectory: URL) throws -> String) -> Outcome {
    var texts: [String] = [], written: [String] = [], failures: [String] = []
    let work: URL
    do { work = try workDirectory() } catch {
      return finish(inputs, texts, written, ["cannot create a temporary directory"])
    }
    defer { try? FileManager.default.removeItem(at: work) }
    for input in inputs {
      let destination = TranscriptOutput.besidePath(for: input, ext: "txt")
      do {
        if TranscriptOutput.sameFile(destination, input) {
          throw TranscriptOutput.Failure("refusing to overwrite the input file: \(input)")
        }
        let transcript = PerlText.bashCapture(try transcribe(URL(fileURLWithPath: input), work))
        guard !PerlText.isBlank(transcript) else {
          throw FileTranscriber.Failure("no speech detected in: \(input)")
        }
        written.append(try TranscriptOutput.writeFirstFree(transcript, to: destination))
        texts.append(transcript)
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    return finish(inputs, texts, written, failures)
  }

  private static func finish(_ inputs: [String], _ texts: [String], _ written: [String],
                             _ failures: [String]) -> Outcome {
    let message: String
    if let last = failures.last {
      message = "Transcription failed: \(last)"
    } else if written.count == 1 {
      message = "Saved \((written[0] as NSString).lastPathComponent) and copied it to the clipboard."
    } else {
      message = "Saved \(inputs.count) transcripts and copied them to the clipboard."
    }
    return Outcome(combined: texts.joined(separator: "\n\n"), written: written, failures: failures,
                   notification: message)
  }
}
