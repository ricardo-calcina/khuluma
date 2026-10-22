import Darwin
import Foundation
import Testing
@testable import KhulumaDaemonKit

/// One-shot latch: `wait()` suspends until `open()` has been called.
private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow: Bool = lock.withLock {
        if isOpen { return true }
        waiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func open() {
    let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter.resume() }
  }
}

/// Answers pings instantly and "transcribes" slowly, without a model.
/// With gates, a transcription opens `entered` and then holds until `release`
/// opens, so a test controls exactly when it is in flight.
private struct FakeHandler: DaemonRequestHandling {
  let transcribeDelay: Duration
  var entered: Gate? = nil
  var release: Gate? = nil

  func handle(_ request: DaemonRequest) async -> DaemonResponse {
    if request.op == .transcribe {
      entered?.open()
      await release?.wait()
      try? await Task.sleep(for: transcribeDelay)
      return DaemonResponse(id: request.id, ok: true, text: "slow result")
    }
    return DaemonResponse(id: request.id, ok: true, message: "ok")
  }
}

/// Minimal blocking client for tests.
private enum TestClient {
  static func connect(to path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var address = try UnixSocketServer.socketAddress(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
  }

  static func send(_ fd: Int32, _ bytes: Data) {
    bytes.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
        if n <= 0 { return }
        sent += n
      }
    }
  }

  static func readLine(_ fd: Int32) throws -> DaemonResponse {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !data.contains(0x0A) {
      let n = recv(fd, &buffer, buffer.count, 0)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    let line = data.prefix(while: { $0 != 0x0A })
    return try JSONDecoder().decode(DaemonResponse.self, from: line)
  }

  static func request(_ path: String, _ request: DaemonRequest) throws -> DaemonResponse {
    let fd = try connect(to: path)
    defer { close(fd) }
    send(fd, try JSONEncoder().encode(request) + Data([0x0A]))
    return try readLine(fd)
  }
}

private func makeSocketPath() throws -> String {
  // Keep it short: sockaddr_un paths are limited to 104 bytes on macOS.
  // Retain each owned fixture root for inspection instead of deleting files.
  let root = "/tmp/khuluma-kit-\(UUID().uuidString.prefix(8))"
  try FileManager.default.createDirectory(
    atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  return root + "/daemon.sock"
}

@Suite(.serialized)
struct UnixSocketServerTests {
  @Test func answersPingWhileATranscriptionIsInFlight() async throws {
    // The transcription cannot finish until the ping has been answered, so a
    // server that served clients one at a time would never answer the ping
    // (the client's 10 s read timeout turns that into a failure, not a hang).
    // No wall-clock bound, so a slow CI runner can't make this flaky.
    let entered = Gate()
    let release = Gate()
    let handler = FakeHandler(transcribeDelay: .zero, entered: entered, release: release)
    let path = try makeSocketPath()
    let server = UnixSocketServer(socketPath: path, handler: handler)
    try server.start()
    defer { server.stop() }
    defer { release.open() }

    let slow = Task.detached {
      // If the request fails before reaching the handler, don't leave the
      // test waiting on `entered`; `slow.value` reports the error below.
      defer { entered.open() }
      return try TestClient.request(path, DaemonRequest(id: "slow", op: .transcribe, wavPath: "/x"))
    }
    await entered.wait()

    let ping = try TestClient.request(path, DaemonRequest(id: "p", op: .ping))
    #expect(ping.ok)
    #expect(ping.id == "p")

    release.open()
    let slowResult = try await slow.value
    #expect(slowResult.text == "slow result")
  }

  @Test func idleClientDoesNotBlockOthers() async throws {
    let path = try makeSocketPath()
    let limits = UnixSocketServer.Limits(readTimeout: 1)
    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero), limits: limits)
    try server.start()
    defer { server.stop() }

    let idle = try TestClient.connect(to: path)
    defer { close(idle) }

    let ping = try TestClient.request(path, DaemonRequest(id: "p", op: .ping))
    #expect(ping.ok)

    // The idle client is dropped with a protocol error once its read times out.
    let timedOut = try TestClient.readLine(idle)
    #expect(timedOut.errorCode == "protocol_error")
  }

  @Test func rejectsOversizedRequest() throws {
    let path = try makeSocketPath()
    let limits = UnixSocketServer.Limits(maxRequestBytes: 1024)
    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero), limits: limits)
    try server.start()
    defer { server.stop() }

    let fd = try TestClient.connect(to: path)
    defer { close(fd) }
    TestClient.send(fd, Data(repeating: 0x61, count: 8192))
    let response = try TestClient.readLine(fd)
    #expect(response.ok == false)
    #expect(response.errorCode == "protocol_error")
    #expect(response.message?.contains("exceeds") == true)
  }

  @Test func garbageRequestGetsProtocolError() throws {
    let path = try makeSocketPath()
    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try server.start()
    defer { server.stop() }

    let fd = try TestClient.connect(to: path)
    defer { close(fd) }
    TestClient.send(fd, Data("not json\n".utf8))
    let response = try TestClient.readLine(fd)
    #expect(response.errorCode == "protocol_error")
    #expect(response.id == "unknown")
  }

  @Test func socketIsPrivateAndRemovedOnStop() throws {
    let path = try makeSocketPath()
    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try server.start()

    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)

    server.stop()
    #expect(lstat(path, &info) != 0)
  }

  @Test func refusesToReplaceARegularFile() throws {
    let path = try makeSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))

    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    #expect(throws: UnixSocketServer.ServerError.self) { try server.start() }
    #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
  }

  @Test func replacesAStaleSocket() throws {
    let path = try makeSocketPath()
    // Simulate a crashed daemon: a bound socket file with nobody listening.
    let orphan = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try UnixSocketServer.socketAddress(for: path)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(orphan, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    close(orphan)
    #expect(bound == 0)

    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try server.start()
    defer { server.stop() }

    let ping = try TestClient.request(path, DaemonRequest(id: "p", op: .ping))
    #expect(ping.ok)
  }

  @Test func refusesToStealALiveDaemonsSocket() throws {
    let path = try makeSocketPath()
    let first = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try first.start()
    defer { first.stop() }

    let second = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    #expect(throws: UnixSocketServer.ServerError.self) { try second.start() }
    let ping = try TestClient.request(path, DaemonRequest(id: "p", op: .ping))
    #expect(ping.ok)
  }

  @Test func stopLeavesASuccessorsSocketAlone() throws {
    let path = try makeSocketPath()
    let old = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try old.start()
    defer { old.stop() }
    // Preserve the old fixture socket under another name, freeing its path
    // for a successor. Stopping the old server must leave the new socket alone.
    try FileManager.default.moveItem(atPath: path, toPath: path + ".previous")
    let successor = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try successor.start()
    defer { successor.stop() }

    old.stop()
    let ping = try TestClient.request(path, DaemonRequest(id: "p", op: .ping))
    #expect(ping.ok)
  }

  @Test func stopDrainsAcceptedWorkAndFreesThePath() async throws {
    let path = try makeSocketPath()
    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .seconds(1)))
    try server.start()

    let inFlight = Task.detached {
      try TestClient.request(path, DaemonRequest(id: "t", op: .transcribe, wavPath: "/x"))
    }
    try await Task.sleep(for: .milliseconds(200))

    let stopped = Task.detached { server.stop(drainTimeout: 5) }
    try await Task.sleep(for: .milliseconds(100))
    // The path is released immediately, so a successor can bind while the
    // old server is still finishing its accepted request.
    let successor = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
    try successor.start()
    defer { successor.stop() }

    let result = try await inFlight.value
    #expect(result.text == "slow result")
    await stopped.value
    #expect(server.activeClientCount == 0)
  }

  @Test func rejectsClientsBeyondTheCap() async throws {
    let path = try makeSocketPath()
    let limits = UnixSocketServer.Limits(maxClients: 1)
    let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .seconds(2)), limits: limits)
    try server.start()
    defer { server.stop() }

    let slow = Task.detached {
      try TestClient.request(path, DaemonRequest(id: "slow", op: .transcribe, wavPath: "/x"))
    }
    try await Task.sleep(for: .milliseconds(200))
    let rejected = try TestClient.request(path, DaemonRequest(id: "p", op: .ping))
    #expect(rejected.errorCode == "busy")
    _ = try await slow.value
  }

  @Test func restartsCleanlyOnTheSamePath() throws {
    let path = try makeSocketPath()
    for round in 0..<3 {
      let server = UnixSocketServer(socketPath: path, handler: FakeHandler(transcribeDelay: .zero))
      try server.start()
      let ping = try TestClient.request(path, DaemonRequest(id: "r\(round)", op: .ping))
      #expect(ping.id == "r\(round)")
      server.stop()
    }
  }
}
