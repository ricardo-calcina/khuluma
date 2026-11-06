import Foundation
import UniformTypeIdentifiers
import os

/// The ElevenLabs Scribe transport, a port of `providers.py transcribe()`.
/// The key is read for one request; it and any response body stay out of
/// logs, errors and arguments (API bodies can echo request data or contain
/// transcripts), so every failure is one of the fixed messages below.
public struct ScribeClient: Sendable {
  public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
  public static let model = "scribe_v2"
  public static let connectTimeout: TimeInterval = 20
  public static let totalTimeout: TimeInterval = 110
  static let fileTimeout: TimeInterval = 600
  static let maxFileBytes = 3_000_000_000

  /// A failure with the CLI's exact wording.
  public enum Failure: Error, LocalizedError, Equatable {
    case noKey
    case fileMissing
    case fileTooLarge
    case couldNotPrepareFile
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
      case .fileTooLarge: return "The file is too large for cloud transcription. Choose a file under 3 GB."
      case .couldNotPrepareFile: return "Khuluma couldn't prepare the file for upload. Check that the file is readable and there's enough disk space."
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
  public typealias FileTransport = @Sendable (_ request: URLRequest, _ bodyFile: URL) throws -> (status: Int?, body: Data)

  let credential: ScribeCredential
  let transport: Transport
  let fileTransport: FileTransport

  public init(credential: ScribeCredential = ScribeCredential(), transport: @escaping Transport = ScribeClient.urlSession,
              fileTransport: @escaping FileTransport = ScribeClient.urlSessionFile) {
    self.credential = credential
    self.transport = transport
    self.fileTransport = fileTransport
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
  public func transcribeMeasured(wav: URL, language: String, tagAudioEvents: Bool = false) throws -> Transcript {
    guard let found = credential.lookup() else { throw Failure.noKey }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: wav.path, isDirectory: &isDirectory), !isDirectory.boolValue,
          let audio = try? Data(contentsOf: wav) else { throw Failure.fileMissing }

    let boundary = "khuluma-" + UUID().uuidString
    let request = Self.request(key: found.key, boundary: boundary, timeout: Self.totalTimeout)
    let (prefix, suffix) = Self.multipartParts(boundary: boundary, fileName: wav.lastPathComponent, contentType: "audio/wav",
                                               language: language, tagAudioEvents: tagAudioEvents)
    var body = prefix
    body.append(audio)
    body.append(suffix)
    return try Self.response { try transport(request, body) }
  }

  /// Uploads the original audio or video once, with sound labels and language detection.
  /// The multipart body lives in the caller's private work directory, not in memory.
  public func transcribeFile(_ file: URL, workDirectory: URL) throws -> String {
    guard let found = credential.lookup() else { throw Failure.noKey }
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw Failure.fileMissing }
    guard size < Self.maxFileBytes else { throw Failure.fileTooLarge }
    let boundary = "khuluma-" + UUID().uuidString
    let type = UTType(filenameExtension: file.pathExtension)
    let fileName = "recording" + (type?.preferredFilenameExtension.map { "." + $0 } ?? "")
    let (prefix, suffix) = Self.multipartParts(boundary: boundary, fileName: fileName,
                                               contentType: type?.preferredMIMEType ?? "application/octet-stream",
                                               language: "auto", tagAudioEvents: true)
    let body = workDirectory.appendingPathComponent("scribe-\(UUID().uuidString).upload")
    defer { try? FileManager.default.removeItem(at: body) }
    do {
      let input = try FileHandle(forReadingFrom: file)
      defer { try? input.close() }
      guard FileManager.default.createFile(atPath: body.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw Failure.couldNotPrepareFile
      }
      let output = try FileHandle(forWritingTo: body)
      defer { try? output.close() }
      try output.write(contentsOf: prefix)
      var written = 0
      while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
        written += chunk.count
        guard written < Self.maxFileBytes else { throw Failure.fileTooLarge }
        try output.write(contentsOf: chunk)
      }
      guard written == size else { throw Failure.couldNotPrepareFile }
      try output.write(contentsOf: suffix)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw Failure.couldNotPrepareFile
    }
    let request = Self.request(key: found.key, boundary: boundary, timeout: Self.fileTimeout)
    return try Self.response { try fileTransport(request, body) }.text
  }

  private static func request(key: String, boundary: String, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    return request
  }

  private static func response(_ send: () throws -> (status: Int?, body: Data)) throws -> Transcript {
    let status: Int?
    let data: Data
    do {
      (status, data) = try send()
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
  private static func multipartParts(boundary: String, fileName: String, contentType: String, language: String,
                                     tagAudioEvents: Bool) -> (Data, Data) {
    func field(_ name: String, _ value: String) -> String {
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
    let prefix = field("model_id", model)
      + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
      + "Content-Type: \(contentType)\r\n\r\n"
    var suffix = "\r\n" + field("tag_audio_events", tagAudioEvents ? "true" : "false")
    if !language.isEmpty, language != "auto" { suffix += field("language_code", language) }
    suffix += "--\(boundary)--\r\n"
    return (Data(prefix.utf8), Data(suffix.utf8))
  }

  /// The real network: a 20 s connect limit (no body byte leaves until the
  /// connection is up) and 110 s in all.
  public static let urlSession: Transport = { request, body in
    try upload(request) { $0.uploadTask(with: request, from: body, completionHandler: $1) }
  }

  public static let urlSessionFile: FileTransport = { request, body in
    try upload(request) { $0.uploadTask(with: request, fromFile: body, completionHandler: $1) }
  }

  private static func upload(
    _ request: URLRequest,
    taskFor: (URLSession, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask
  ) throws -> (status: Int?, body: Data) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = request.timeoutInterval
    configuration.timeoutIntervalForResource = request.timeoutInterval
    configuration.waitsForConnectivity = false
    let watcher = ConnectWatcher()
    let session = URLSession(configuration: configuration, delegate: watcher, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let done = DispatchSemaphore(value: 0)
    let result = OSAllocatedUnfairLock(initialState: (nil as Data?, nil as URLResponse?, nil as Error?))
    let task = taskFor(session) { data, response, error in
      result.withLock { $0 = (data, response, error) }
      done.signal()
    }
    watcher.arm(task, after: connectTimeout)
    task.resume()
    done.wait()
    watcher.disarm()
    let (data, response, error) = result.withLock { $0 }
    if let error { throw error }
    return ((response as? HTTPURLResponse)?.statusCode, data ?? Data())
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

  // The credential and recording belong only at the declared endpoint.
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    lock.lock(); connected = true; lock.unlock()
  }
}
