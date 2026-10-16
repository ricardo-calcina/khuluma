import Foundation
import KhulumaObjC

/// An Objective-C exception (NSException) turned into a Swift error.
public struct ObjCException: LocalizedError, Equatable, CustomStringConvertible {
  public let name: String
  public let reason: String

  public var description: String { "\(name): \(reason)" }
  public var errorDescription: String? { description }

  /// Runs `body`, turning an NSException it raises into an `ObjCException`.
  /// Swift errors and return values pass through unchanged. Keep `body`
  /// small: the exception unwinds through it without running Swift cleanup.
  public static func catching<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    do {
      try KHObjC.catchException {
        result = Result { try body() }
      }
    } catch let error as NSError where error.domain == KHObjCExceptionDomain {
      throw ObjCException(name: error.userInfo[KHObjCExceptionNameKey] as? String ?? "NSException",
                          reason: error.userInfo[KHObjCExceptionReasonKey] as? String ?? "")
    }
    // A block that returns normally always set the result.
    return try result!.get()
  }
}

/// Starts one take at a time, and never leaves its take marker behind.
///
/// A marker published for a start that never finishes keeps the CLI's idle
/// check busy (blocking daemon upgrades) for as long as Lowkey runs. That
/// happened when AVAudioEngine raised an Objective-C exception from the
/// hotkey handler: Swift's `catch` never ran, HIToolbox swallowed the
/// exception, and every later press replayed the chime and leaked another
/// marker. Here a failed start of any kind removes its marker, and a press
/// that arrives while a start is still running (through a nested run loop)
/// is refused instead of stacking a second start.
public final class TakeStarter {
  public enum Outcome<Value> {
    case started(Value, marker: TakeMarker?)
    /// Another start was still in progress; nothing was done.
    case busy
    /// Capture didn't start; the marker is already removed.
    case failed(Error)
  }

  public private(set) var isStarting = false

  public init() {}

  /// Publishes the marker, then starts capture. Call on one thread (main).
  public func start<Value>(marker makeMarker: () -> TakeMarker?,
                           capture: () throws -> Value) -> Outcome<Value> {
    guard !isStarting else { return .busy }
    isStarting = true
    defer { isStarting = false }
    let marker = makeMarker()
    do {
      return .started(try ObjCException.catching(capture), marker: marker)
    } catch {
      marker?.remove()
      return .failed(error)
    }
  }
}

/// One retry after recovery, for starting capture: the first failure may
/// be a stale engine for an input device that has since changed.
public enum RetryOnce {
  /// Runs `attempt`; if it throws, runs `recover` with that error and tries
  /// once more. The second failure (or a failing `recover`) is thrown.
  public static func run<T>(_ attempt: () throws -> T, recover: (Error) throws -> Void) throws -> T {
    do {
      return try attempt()
    } catch {
      try recover(error)
      return try attempt()
    }
  }
}

/// Something that should happen at most once, from whichever thread gets
/// there first: the start chime fires on the first audio buffer (audio
/// thread) or a fallback timer (main), and never after the take stopped.
public final class OneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false

  public init() {}

  /// True for the first caller only (and never after `cancel`).
  public func fire() -> Bool {
    lock.withLock {
      defer { done = true }
      return !done
    }
  }

  public func cancel() {
    lock.withLock { done = true }
  }
}
