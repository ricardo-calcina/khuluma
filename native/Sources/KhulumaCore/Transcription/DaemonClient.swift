import Darwin
import Foundation

/// Client for khulumad's line-delimited JSON protocol on its Unix socket
/// (KhulumaDaemonKit's DaemonRequest/DaemonResponse; the wire format is checked
/// against those types in tests). Blocking: call it off the main thread.
public struct DaemonClient: Sendable {
  public enum ClientError: Error, Equatable, LocalizedError {
    /// The socket could not be reached: the daemon is not running. Nothing
    /// was sent, so retrying or falling back is safe.
    case unreachable(String)
    /// No complete response before the deadline. The request may still be
    /// running in the daemon.
    case timedOut(Double)
    /// The connection broke or returned something that is not a response.
    case protocolError(String)
    /// The daemon answered with ok=false.
    case daemon(code: String, message: String)

    public var errorDescription: String? {
      switch self {
      case .unreachable(let detail): return "Parakeet daemon unreachable: \(detail)"
      case .timedOut(let seconds): return "Parakeet daemon did not answer within \(Int(seconds))s"
      case .protocolError(let detail): return "Parakeet daemon protocol error: \(detail)"
      case .daemon(let code, let message): return "Parakeet daemon error \(code): \(message)"
      }
    }
  }

  struct Request: Encodable {
    let id: String
    let op: String
    var wavPath: String?
    var language: String?
    var flow: String?
    var modelPath: String?
    var modelVersion: String?

    enum CodingKeys: String, CodingKey {
      case id, op, language, flow
      case wavPath = "wav_path"
      case modelPath = "model_path"
      case modelVersion = "model_version"
    }
  }

  struct Response: Decodable {
    let id: String
    let ok: Bool
    let text: String?
    let errorCode: String?
    let message: String?
    let version: String?
    let pid: Int?
    let generation: String?
    let modelLoaded: DaemonStatus.LoadedModel?
    let activeRequests: Int?
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
      case id, ok, text, message, version, pid, generation
      case errorCode = "error_code"
      case durationMs = "duration_ms"
      case modelLoaded = "model_loaded"
      case activeRequests = "active_requests"
    }
  }

  public let socketPath: String
  /// Delay before the one reconnect attempt after an unreachable socket.
  public var retryDelay: TimeInterval = 0.1
  static let maxResponseBytes = 4 << 20

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  /// Daemon version, or nil when it does not answer within `timeout`.
  public func ping(timeout: TimeInterval = 1) -> String? {
    status(timeout: timeout)?.version
  }

  /// What the daemon reports about itself, or nil when it does not answer
  /// within `timeout`. One attempt: a probe must stay bounded.
  public func status(timeout: TimeInterval) -> DaemonStatus? {
    guard let response = try? sendOnce(Request(id: UUID().uuidString, op: "ping"), timeout: timeout),
          response.ok else { return nil }
    return DaemonStatus(version: response.version ?? "", pid: response.pid, generation: response.generation,
                        modelLoaded: response.modelLoaded, activeRequests: response.activeRequests)
  }

  /// Transcribes a 16 kHz mono 16-bit WAV the daemon can read.
  public func transcribe(
    wav: URL, language: String, flow: String, modelPath: String, modelVersion: String?, timeout: TimeInterval
  ) throws -> String {
    try transcribePass(wav: wav, language: language, flow: flow, modelPath: modelPath, modelVersion: modelVersion,
                       timeout: timeout).text
  }

  /// `transcribe`, with the daemon's own timing.
  public func transcribePass(
    wav: URL, language: String, flow: String, modelPath: String, modelVersion: String?, timeout: TimeInterval
  ) throws -> NativeTranscriber.Pass {
    let request = Request(
      id: UUID().uuidString, op: "transcribe", wavPath: wav.path, language: language, flow: flow,
      modelPath: modelPath, modelVersion: modelVersion)
    let response = try send(request, timeout: timeout)
    guard response.ok else {
      throw ClientError.daemon(code: response.errorCode ?? "unknown", message: response.message ?? "unknown error")
    }
    return NativeTranscriber.Pass(text: response.text ?? "", daemonMs: response.durationMs)
  }

  /// One request; reconnects once if the socket was unreachable.
  func send(_ request: Request, timeout: TimeInterval) throws -> Response {
    do {
      return try sendOnce(request, timeout: timeout)
    } catch ClientError.unreachable {
      Thread.sleep(forTimeInterval: retryDelay)
      return try sendOnce(request, timeout: timeout)
    }
  }

  private func sendOnce(_ request: Request, timeout: TimeInterval) throws -> Response {
    let deadline = Date().addingTimeInterval(timeout)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ClientError.unreachable("socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    // Set before connecting: once the daemon has answered and closed (fast
    // replies such as errors), macOS rejects setsockopt with EINVAL.
    try setTimeout(fd, SO_SNDTIMEO, seconds: timeout, tolerateClosed: false)
    try setTimeout(fd, SO_RCVTIMEO, seconds: timeout, tolerateClosed: false)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw ClientError.unreachable("socket path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: pathBytes)
      raw[pathBytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      throw ClientError.unreachable("\(socketPath): \(String(cString: strerror(errno)))")
    }

    let encoder = JSONEncoder()
    var line = try encoder.encode(request)
    line.append(0x0A)
    try setTimeout(fd, SO_SNDTIMEO, seconds: max(0.05, deadline.timeIntervalSinceNow))
    try line.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
        if written < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK { throw ClientError.timedOut(timeout) }
          throw ClientError.protocolError("send: \(String(cString: strerror(errno)))")
        }
        offset += written
      }
    }

    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !received.contains(0x0A) {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw ClientError.timedOut(timeout) }
      try setTimeout(fd, SO_RCVTIMEO, seconds: remaining)
      let count = recv(fd, &buffer, buffer.count, 0)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { throw ClientError.timedOut(timeout) }
        throw ClientError.protocolError("recv: \(String(cString: strerror(errno)))")
      }
      if count == 0 { break }
      received.append(contentsOf: buffer[0..<count])
      if received.count > Self.maxResponseBytes { throw ClientError.protocolError("response too large") }
    }
    let lineEnd = received.firstIndex(of: 0x0A) ?? received.endIndex
    let body = received[received.startIndex..<lineEnd]
    guard !body.isEmpty else { throw ClientError.protocolError("empty response") }
    do {
      return try JSONDecoder().decode(Response.self, from: body)
    } catch {
      throw ClientError.protocolError("bad response: \(String(decoding: body.prefix(200), as: UTF8.self))")
    }
  }

  /// Sets a socket timeout. For later updates (shortening it to the time
  /// left), EINVAL means the peer has already closed: its reply is buffered
  /// and recv returns at once, so the initial timeout still bounds the wait.
  private func setTimeout(_ fd: Int32, _ option: Int32, seconds: TimeInterval, tolerateClosed: Bool = true) throws {
    var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
    if value.tv_sec == 0 && value.tv_usec == 0 { value.tv_usec = 1000 }
    guard setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
      if errno == EINVAL && tolerateClosed { return }
      throw ClientError.protocolError("setsockopt: \(String(cString: strerror(errno)))")
    }
  }
}

/// A ping's answer. Daemons before 0.3.0 report only the version.
public struct DaemonStatus: Equatable, Sendable {
  public struct LoadedModel: Decodable, Equatable, Sendable {
    public let path: String
    public let version: String

    public init(path: String, version: String) {
      self.path = path
      self.version = version
    }
  }

  public let version: String
  public let pid: Int?
  /// Per-process id: a new value means a new, cold daemon.
  public let generation: String?
  public let modelLoaded: LoadedModel?
  public let activeRequests: Int?

  public init(version: String, pid: Int? = nil, generation: String? = nil, modelLoaded: LoadedModel? = nil,
              activeRequests: Int? = nil) {
    self.version = version
    self.pid = pid
    self.generation = generation
    self.modelLoaded = modelLoaded
    self.activeRequests = activeRequests
  }

  /// This daemon reports having exactly this model loaded. False for older
  /// daemons, which don't say.
  public func holds(path: String, version: String) -> Bool {
    modelLoaded == LoadedModel(path: path, version: version)
  }
}
