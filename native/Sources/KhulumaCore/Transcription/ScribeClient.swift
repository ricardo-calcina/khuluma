import Foundation

/// The ElevenLabs Scribe transport, a port of `providers.py transcribe()`.
/// The key is read for one request; it and any response body stay out of
/// logs, errors and arguments (API bodies can echo request data or contain
/// transcripts), so every failure is one of the fixed messages below.
public struct ScribeClient: Sendable {
  public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
  public static let model = "scribe_v2"
  public static let connectTimeout: TimeInterval = 20
  public static let totalTimeout: TimeInterval = 110

  /// A failure with the CLI's exact wording.
  public enum Failure: Error, LocalizedError, Equatable {
    case noKey
    case fileMissing
    case couldNotComplete
    case unreadableResponse
    case authentication(Int)
    case limit
    case http(Int)
    case unreadableTranscript

    public var errorDescription: String? {
      switch self {
      case .noKey:
        return "ElevenLabs API key unavailable. Add it in Khuluma's Settings, or export ELEVENLABS_API_KEY in your shell settings, then reload Settings."
      case .fileMissing: return "ElevenLabs audio file is unavailable."
      case .couldNotComplete: return "ElevenLabs request could not complete. Check your connection and retry."
      case .unreadableResponse: return "ElevenLabs returned an unreadable response."
      case .authentication(let status):
        return "ElevenLabs authentication failed (HTTP \(status)). Check your API key and speech-to-text access."
      case .limit: return "ElevenLabs request limit reached (HTTP 429). Check account limits and retry later."
      case .http(let status):
        return "ElevenLabs transcription failed (HTTP \(status)). The recording is kept when recovery is available."
      case .unreadableTranscript: return "ElevenLabs returned an unreadable transcript."
      }
    }
  }

  /// Sends one request and returns the status and body, or throws for a
  /// network failure. `nil` status means the answer was not HTTP.
  public typealias Transport = @Sendable (_ request: URLRequest, _ body: Data) throws -> (status: Int?, body: Data)

  let credential: ScribeCredential
  let transport: Transport

  public init(credential: ScribeCredential = ScribeCredential(), transport: @escaping Transport = ScribeClient.urlSession) {
    self.credential = credential
    self.transport = transport
  }

  /// A transcript and, when Scribe sent word timings, the time spent speaking.
  public struct Transcript: Equatable, Sendable {
    public let text: String
    public let speechMs: Int?
  }

  /// Transcribes one WAV file. `language` "auto" or empty lets Scribe detect it.
  public func transcribe(wav: URL, language: String) throws -> String {
    try transcribeMeasured(wav: wav, language: language).text
  }

  /// `transcribe`, with speaking time from the response's `words`.
  public func transcribeMeasured(wav: URL, language: String) throws -> Transcript {
    guard let found = credential.lookup() else { throw Failure.noKey }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: wav.path, isDirectory: &isDirectory), !isDirectory.boolValue,
          let audio = try? Data(contentsOf: wav) else { throw Failure.fileMissing }

    let boundary = "khuluma-" + UUID().uuidString
    var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.totalTimeout)
    request.httpMethod = "POST"
    request.setValue(found.key, forHTTPHeaderField: "xi-api-key")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let body = Self.multipart(boundary: boundary, audio: audio, fileName: wav.lastPathComponent, language: language)

    let status: Int?
    let data: Data
    do {
      (status, data) = try transport(request, body)
    } catch {
      throw Failure.couldNotComplete
    }
    guard let status else { throw Failure.unreadableResponse }
    guard status == 200 else {
      switch status {
      case 401, 403: throw Failure.authentication(status)
      case 429: throw Failure.limit
      default: throw Failure.http(status)
      }
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["text"] as? String else { throw Failure.unreadableTranscript }
    return Transcript(text: text, speechMs: Self.speechMs(words: object["words"]))
  }

  /// Speaking time from Scribe's `words` (seconds; only type "word" counts).
  /// Anything missing or odd gives nil.
  static func speechMs(words: Any?) -> Int? {
    guard let words = words as? [[String: Any]] else { return nil }
    let spans: [(Int, Int)] = words.compactMap { word in
      guard (word["type"] as? String) == "word",
            let start = (word["start"] as? NSNumber)?.doubleValue,
            let end = (word["end"] as? NSNumber)?.doubleValue,
            start.isFinite, end.isFinite else { return nil }
      let startMs = (start * 1000).rounded(), endMs = (end * 1000).rounded()
      // Up to ~100 days: anything past that is not a real timestamp.
      let limit = 1e10
      guard abs(startMs) < limit, abs(endMs) < limit else { return nil }
      return (Int(startMs), Int(endMs))
    }
    return SpeechTime.speechMs(pairs: spans)
  }

  /// Fields in the order the CLI's curl sent them.
  static func multipart(boundary: String, audio: Data, fileName: String, language: String) -> Data {
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    field("model_id", model)
    let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
    body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
                      + "Content-Type: audio/wav\r\n\r\n").utf8))
    body.append(audio)
    body.append(Data("\r\n".utf8))
    field("tag_audio_events", "false")
    if !language.isEmpty, language != "auto" { field("language_code", language) }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
  }

  /// The real network: a 20 s connect limit (no body byte leaves until the
  /// connection is up) and 110 s in all.
  public static let urlSession: Transport = { request, body in
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = totalTimeout
    configuration.timeoutIntervalForResource = totalTimeout
    configuration.waitsForConnectivity = false
    let watcher = ConnectWatcher()
    let session = URLSession(configuration: configuration, delegate: watcher, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    let task = session.uploadTask(with: request, from: body) { data, response, error in
      result = (data, response, error)
      done.signal()
    }
    watcher.arm(task, after: connectTimeout)
    task.resume()
    done.wait()
    watcher.disarm()
    if let error = result.2 { throw error }
    guard let http = result.1 as? HTTPURLResponse else { return (nil, result.0 ?? Data()) }
    return (http.statusCode, result.0 ?? Data())
  }
}

/// Cancels a request whose connection isn't up within the limit.
private final class ConnectWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var connected = false
  private var item: DispatchWorkItem?

  func arm(_ task: URLSessionTask, after seconds: TimeInterval) {
    let item = DispatchWorkItem { [weak self, weak task] in
      guard let self, let task else { return }
      self.lock.lock(); let up = self.connected; self.lock.unlock()
      if !up { task.cancel() }
    }
    lock.lock(); self.item = item; lock.unlock()
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
  }

  func disarm() { lock.lock(); item?.cancel(); lock.unlock() }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    lock.lock(); connected = true; lock.unlock()
  }
}
