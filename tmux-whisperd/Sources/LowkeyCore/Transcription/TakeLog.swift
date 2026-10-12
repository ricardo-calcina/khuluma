import Foundation

/// The one transcript-free `take:` line each take writes to app.log, read by
/// tools/lowkey-report.sh: space-separated `key=value` pairs. A value with a
/// space, quote, backslash or `=` is double-quoted, with `\"` and `\\`
/// escapes. Nil values are left out.
public struct TakeLog: Sendable {
  public struct Field: Equatable, Sendable {
    public let key: String
    public let value: String
  }

  public private(set) var fields: [Field] = []

  public init() {}

  public mutating func add(_ key: String, _ value: String?) {
    guard let value else { return }
    fields.append(Field(key: key, value: value))
  }

  public mutating func add(_ key: String, _ value: Int?) {
    add(key, value.map(String.init))
  }

  /// Milliseconds, rounded to whole ms.
  public mutating func add(_ key: String, ms value: Double?) {
    add(key, value.map { Int($0.rounded()) })
  }

  public var line: String {
    (["take:"] + fields.map { "\($0.key)=\(Self.quoted($0.value))" }).joined(separator: " ")
  }

  static func quoted(_ value: String) -> String {
    let plain = !value.isEmpty && !value.unicodeScalars.contains {
      $0 == " " || $0 == "\"" || $0 == "\\" || $0 == "=" || CharacterSet.whitespacesAndNewlines.contains($0)
    }
    if plain { return value }
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n", "\r", "\t": out += " "
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}

/// What the daemon was doing when a take was handed to it, from a ping sent
/// at stop alongside WAV prep (so it costs the take nothing when it answers
/// in time).
public enum TakeDaemonState: String, Sendable {
  /// Our model loaded, nothing else in flight.
  case warm
  /// Not answering, or our model not loaded: this take pays the load.
  case cold
  /// Our model loaded, but another warmup or transcription was in flight.
  case contended
  /// No answer in time, or a daemon too old to say.
  case unknown

  public static func classify(_ status: DaemonStatus?, modelPath: String, modelVersion: String) -> Self {
    guard let status else { return .cold }
    guard status.pid != nil else { return .unknown }
    guard status.holds(path: modelPath, version: modelVersion) else { return .cold }
    return (status.activeRequests ?? 0) > 0 ? .contended : .warm
  }
}

/// A ping started in the background; `state` waits a bounded time for it.
/// A late answer is ignored: by then the take's own request may be in flight
/// and would count as contention.
public final class TakeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var status: DaemonStatus?
  private var answered = false
  private var settled: TakeDaemonState?
  private var waited: Double = 0

  public init(queue: DispatchQueue = .global(qos: .userInitiated), ping: @escaping @Sendable () -> DaemonStatus?) {
    queue.async { [self] in
      let status = ping()
      lock.withLock {
        self.status = status
        answered = true
      }
      done.signal()
    }
  }

  /// How long the first `state` call waited for the ping, in ms.
  public var waitedMs: Double { lock.withLock { waited } }

  /// The daemon's state at stop; `.unknown` when the ping hasn't answered
  /// within `timeout`. Settled by the first call.
  public func state(waiting timeout: TimeInterval, modelPath: String, modelVersion: String) -> TakeDaemonState {
    if let settled = lock.withLock({ settled }) { return settled }
    let start = DispatchTime.now().uptimeNanoseconds
    _ = done.wait(timeout: .now() + timeout)
    let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return lock.withLock {
      if let settled { return settled }
      let state = answered ? TakeDaemonState.classify(status, modelPath: modelPath, modelVersion: modelVersion) : .unknown
      settled = state
      waited = waitedMs
      return state
    }
  }
}
