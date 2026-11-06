import Foundation

/// The Quick Action's work, as the CLI's Finder handler did it
/// (`khuluma transcribe --beside --clipboard`): `<name>.txt` beside each file,
/// never over an existing one (that file fails, as with the CLI), the
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
                         waitWhileBusy: () -> Void, workDirectory: () throws -> URL,
                         transcriber: FileTranscriber = FileTranscriber()) -> Outcome {
    var texts: [String] = [], written: [String] = [], failures: [String] = []
    let work: URL
    do { work = try workDirectory() } catch {
      return finish(inputs, texts, written, ["cannot create a temporary directory"])
    }
    defer { try? FileManager.default.removeItem(at: work) }
    for input in inputs {
      let destination = TranscriptOutput.besidePath(for: input, ext: "txt")
      do {
        try TranscriptOutput.precheck(destination: destination, input: input, force: false)
        waitWhileBusy()
        let transcript = try transcriber.transcribe(URL(fileURLWithPath: input), label: input,
                                                    workDirectory: work, engine: try engine())
        try TranscriptOutput.write(transcript.text, to: destination, force: false)
        texts.append(transcript.text)
        written.append(destination)
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
    } else if inputs.count == 1 {
      let name = ((inputs[0] as NSString).lastPathComponent as NSString).deletingPathExtension
      message = "Saved \(name).txt and copied it to the clipboard."
    } else {
      message = "Saved \(inputs.count) transcripts and copied them to the clipboard."
    }
    return Outcome(combined: texts.joined(separator: "\n\n"), written: written, failures: failures,
                   notification: message)
  }
}
