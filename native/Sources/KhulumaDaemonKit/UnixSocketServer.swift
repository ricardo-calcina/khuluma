import Darwin
import Foundation

/// Line-delimited JSON server on a Unix domain socket.
///
/// `accept` runs on a dedicated thread and every client gets its own thread,
/// so blocking socket calls never occupy the Swift concurrency pool and a quick
/// `ping` is answered while a long transcription is in progress.
public final class UnixSocketServer: @unchecked Sendable {
  public struct Limits: Sendable {
    /// Largest accepted request line, in bytes.
    public var maxRequestBytes: Int
    /// How long a client may take to send its request line.
    public var readTimeout: TimeInterval
    /// How long a response write may block on a stalled client.
    public var writeTimeout: TimeInterval
    /// Clients served at once; further connections get an immediate "busy".
    public var maxClients: Int

    public init(
      maxRequestBytes: Int = 1 << 20,
      readTimeout: TimeInterval = 10,
      writeTimeout: TimeInterval = 30,
      maxClients: Int = 32
    ) {
      self.maxRequestBytes = maxRequestBytes
      self.readTimeout = readTimeout
      self.writeTimeout = writeTimeout
      self.maxClients = maxClients
    }
  }

  public enum ServerError: Error, LocalizedError {
    case socketPathTooLong(String)
    case socketPathOccupied(String)
    case alreadyServing(String)
    case posix(String, Int32)

    public var errorDescription: String? {
      switch self {
      case .socketPathTooLong(let path):
        return "socket path is too long: \(path)"
      case .socketPathOccupied(let path):
        return "refusing to replace a non-socket file at \(path)"
      case .alreadyServing(let path):
        return "another daemon is already listening on \(path)"
      case .posix(let call, let code):
        return "\(call) failed: \(String(cString: strerror(code)))"
      }
    }
  }

  private let socketPath: String
  private let handler: any DaemonRequestHandling
  private let limits: Limits
  private let lock = NSLock()
  private var serverFD: Int32 = -1
  /// Self-pipe that wakes the accept loop on stop().
  private var wakeFDs: (read: Int32, write: Int32) = (-1, -1)
  private var stopped = false
  private var activeClients = 0
  /// Identity of the socket file this server created, so stop() never
  /// removes a socket that a newer daemon has since bound at the same path.
  private var boundSocket: (dev: dev_t, ino: ino_t)?

  public init(socketPath: String, handler: any DaemonRequestHandling, limits: Limits = Limits()) {
    self.socketPath = socketPath
    self.handler = handler
    self.limits = limits
  }

  deinit {
    stop()
  }

  /// Binds and starts accepting in the background. Returns once the socket is
  /// listening.
  public func start() throws {
    // A client that disconnects before its response is written must never
    // kill the process. SO_NOSIGPIPE alone is not enough: setsockopt fails on
    // a socket whose peer has already gone, so ignore SIGPIPE process-wide and
    // let writes fail with EPIPE instead.
    signal(SIGPIPE, SIG_IGN)
    try prepareSocketPath()

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw ServerError.posix("socket", errno)
    }

    do {
      var address = try Self.socketAddress(for: socketPath)
      let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
          bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bindResult == 0 else {
        throw ServerError.posix("bind", errno)
      }
      // Only this user may talk to the daemon (it reads arbitrary paths).
      guard chmod(socketPath, 0o600) == 0 else {
        throw ServerError.posix("chmod", errno)
      }
      guard listen(fd, SOMAXCONN) == 0 else {
        throw ServerError.posix("listen", errno)
      }
    } catch {
      close(fd)
      throw error
    }

    var pipeFDs: [Int32] = [-1, -1]
    guard pipe(&pipeFDs) == 0 else {
      close(fd)
      throw ServerError.posix("pipe", errno)
    }
    // The accept loop may have exited (closing the read end) by the time
    // stop() writes; that must be EPIPE, not a process-killing SIGPIPE.
    _ = fcntl(pipeFDs[1], F_SETNOSIGPIPE, 1)
    // Non-blocking listener: poll() can report a connection that is gone by
    // the time accept() runs.
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    var info = stat()
    let identity: (dev: dev_t, ino: ino_t)? = lstat(socketPath, &info) == 0 ? (info.st_dev, info.st_ino) : nil
    lock.withLock {
      serverFD = fd
      wakeFDs = (pipeFDs[0], pipeFDs[1])
      stopped = false
      boundSocket = identity
    }

    let wakeRead = pipeFDs[0]
    let thread = Thread { [self] in acceptLoop(fd: fd, wakeFD: wakeRead) }
    thread.name = "khulumad.accept"
    thread.start()
  }

  /// Starts the server and suspends forever. Used by `khulumad serve`.
  public func run() async throws {
    try start()
    while true {
      try await Task.sleep(for: .seconds(3600))
    }
  }

  /// Stops accepting and removes this server's socket file, then waits up to
  /// `drainTimeout` seconds for requests already accepted to finish. New
  /// clients can connect to a replacement daemon as soon as this returns
  /// from the unlink, so a restart never interrupts accepted work.
  public func stop(drainTimeout: TimeInterval = 0) {
    let (fd, wakeWrite, identity): (Int32, Int32, (dev: dev_t, ino: ino_t)?) = lock.withLock {
      guard !stopped else { return (-1, -1, nil) }
      stopped = true
      let fd = serverFD
      serverFD = -1
      return (fd, wakeFDs.write, boundSocket)
    }
    guard fd >= 0 else { return }
    // Remove the path first so no new client reaches this server; a
    // replacement daemon can bind it straight away.
    Self.unlinkIfSameSocket(socketPath, identity: identity)
    // Wake the accept loop; it closes the listener and the read end on exit.
    // stop() owns the write end, so the descriptor can't be closed and reused
    // underneath this write.
    var byte: UInt8 = 1
    _ = write(wakeWrite, &byte, 1)
    close(wakeWrite)

    let deadline = Date().addingTimeInterval(drainTimeout)
    while activeClientCount > 0, Date() < deadline {
      usleep(50_000)
    }
  }

  /// Clients currently being served (read, handled, or written).
  public var activeClientCount: Int {
    lock.withLock { activeClients }
  }

  private var isStopped: Bool {
    lock.withLock { stopped }
  }

  private func acceptLoop(fd: Int32, wakeFD: Int32) {
    defer {
      close(fd)
      close(wakeFD)
    }

    while !isStopped {
      var fds = [
        pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
      ]
      let ready = poll(&fds, nfds_t(fds.count), -1)
      if ready < 0 {
        if errno == EINTR { continue }
        usleep(50_000)
        continue
      }
      if fds[1].revents != 0 || isStopped {
        return
      }
      guard fds[0].revents & Int16(POLLIN) != 0 else { continue }

      let clientFD = accept(fd, nil, nil)
      if clientFD < 0 {
        // EAGAIN/ECONNABORTED: the client went away. Anything else (e.g.
        // EMFILE) is transient and must not kill the daemon.
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != ECONNABORTED && errno != EINTR {
          usleep(50_000)
        }
        continue
      }
      // Accepted sockets inherit O_NONBLOCK on Darwin; clients use blocking
      // I/O bounded by SO_RCVTIMEO/SO_SNDTIMEO.
      _ = fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL) & ~O_NONBLOCK)

      configureClient(clientFD)
      let admitted: Bool = lock.withLock {
        guard activeClients < self.limits.maxClients else { return false }
        activeClients += 1
        return true
      }
      guard admitted else {
        let busy = DaemonResponse.failure(id: "unknown", code: "busy", message: "too many concurrent clients")
        if let data = try? JSONEncoder().encode(busy) {
          try? Self.writeAll(fd: clientFD, data: data + Data([0x0A]))
        }
        close(clientFD)
        continue
      }

      let handler = self.handler
      let clientLimits = self.limits
      let thread = Thread { [self] in
        Self.serveClient(fd: clientFD, handler: handler, limits: clientLimits)
        lock.withLock { activeClients -= 1 }
      }
      thread.name = "khulumad.client"
      thread.start()
    }
  }

  private func configureClient(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var readTimeout = Self.timeval(from: limits.readTimeout)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
    var writeTimeout = Self.timeval(from: limits.writeTimeout)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
  }

  private static func serveClient(fd: Int32, handler: any DaemonRequestHandling, limits: Limits) {
    defer { close(fd) }

    let response: DaemonResponse
    do {
      let line = try readRequestLine(from: fd, maxBytes: limits.maxRequestBytes)
      let request = try JSONDecoder().decode(DaemonRequest.self, from: line)
      response = awaitResponse(handler: handler, request: request)
    } catch {
      response = .failure(id: "unknown", code: "protocol_error", message: error.localizedDescription)
    }

    guard let data = try? JSONEncoder().encode(response) else { return }
    try? writeAll(fd: fd, data: data + Data([0x0A]))
  }

  /// Bridges the async handler onto this client's dedicated thread.
  private static func awaitResponse(handler: any DaemonRequestHandling, request: DaemonRequest) -> DaemonResponse {
    final class Box: @unchecked Sendable {
      var response: DaemonResponse?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task {
      box.response = await handler.handle(request)
      done.signal()
    }
    done.wait()
    return box.response ?? .failure(id: request.id, code: "runtime_error", message: "no response")
  }

  static func readRequestLine(from fd: Int32, maxBytes: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
      let readCount = recv(fd, &buffer, buffer.count, 0)
      if readCount < 0 {
        if errno == EINTR {
          continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          throw DaemonServiceError.invalidRequest("timed out waiting for request")
        }
        throw ServerError.posix("recv", errno)
      }
      if readCount == 0 {
        break
      }
      data.append(buffer, count: readCount)
      if let newline = data.firstIndex(of: 0x0A) {
        data = data.prefix(upTo: newline)
        break
      }
      if data.count > maxBytes {
        throw DaemonServiceError.invalidRequest("request exceeds \(maxBytes) bytes")
      }
    }

    if data.count > maxBytes {
      throw DaemonServiceError.invalidRequest("request exceeds \(maxBytes) bytes")
    }
    if data.isEmpty {
      throw DaemonServiceError.invalidRequest("empty request")
    }
    return data
  }

  private static func writeAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else {
        return
      }
      var total = 0
      while total < rawBuffer.count {
        let written = send(fd, base.advanced(by: total), rawBuffer.count - total, 0)
        if written < 0 {
          if errno == EINTR {
            continue
          }
          throw ServerError.posix("send", errno)
        }
        total += written
      }
    }
  }

  private func prepareSocketPath() throws {
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var info = stat()
    if lstat(socketPath, &info) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw ServerError.socketPathOccupied(socketPath)
      }
      // A live daemon owns this socket: never steal it. Only a socket left by
      // a crashed daemon (nobody accepting) is replaced.
      if Self.isAcceptingConnections(socketPath) {
        throw ServerError.alreadyServing(socketPath)
      }
      unlink(socketPath)
    }
  }

  private static func unlinkIfSameSocket(_ path: String, identity: (dev: dev_t, ino: ino_t)?) {
    guard let identity else { return }
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return }
    guard info.st_dev == identity.dev, info.st_ino == identity.ino else { return }
    unlink(path)
  }

  private static func isAcceptingConnections(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard var address = try? socketAddress(for: path) else { return false }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
        connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return result == 0
  }

  static func socketAddress(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = path.utf8CString
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= pathCapacity else {
      throw ServerError.socketPathTooLong(path)
    }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      _ = pathBytes.withUnsafeBytes { src in
        memcpy(buffer.baseAddress!, src.baseAddress!, min(buffer.count, src.count))
      }
    }
    return address
  }

  private static func timeval(from seconds: TimeInterval) -> Darwin.timeval {
    let whole = max(0, Int(seconds))
    let micros = Int32(max(0, (seconds - Double(whole)) * 1_000_000))
    return Darwin.timeval(tv_sec: whole, tv_usec: micros)
  }
}
