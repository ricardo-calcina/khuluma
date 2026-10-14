import Foundation
import Testing
@testable import LowkeyCore

/// What AVAudioEngine raises for a tap in the format of a device that is no
/// longer the input (the 2026-10-11 headphones bug); message as observed.
private func raiseAVAudioEngineAssertion() {
  NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
              reason: "Failed to create tap due to format mismatch, <AVAudioFormat 0x1:  1 ch,  24000 Hz, Float32>",
              userInfo: nil).raise()
}

private struct CaptureFailed: Error, Equatable {}

struct ObjCExceptionTests {
  @Test func anNSExceptionBecomesASwiftError() {
    #expect(throws: ObjCException(name: "com.apple.coreaudio.avfaudio",
                                  reason: "Failed to create tap due to format mismatch, <AVAudioFormat 0x1:  1 ch,  24000 Hz, Float32>")) {
      try ObjCException.catching { raiseAVAudioEngineAssertion() }
    }
    do {
      try ObjCException.catching { raiseAVAudioEngineAssertion() }
      Issue.record("expected an error")
    } catch {
      #expect(error.localizedDescription
              == "com.apple.coreaudio.avfaudio: Failed to create tap due to format mismatch, <AVAudioFormat 0x1:  1 ch,  24000 Hz, Float32>")
    }
  }

  @Test func valuesAndSwiftErrorsPassThrough() throws {
    #expect(try ObjCException.catching { 42 } == 42)
    #expect(throws: CaptureFailed()) { try ObjCException.catching { throw CaptureFailed() } }
  }
}

struct TakeStarterTests {
  private func markerDir() -> String { NSTemporaryDirectory() + "lk-starter-\(UUID().uuidString)" }
  private func markers(in dir: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
  }

  @Test func pressesAfterAnEngineExceptionLeaveNoMarkers() {
    // Four presses, each one raising from AVAudioEngine: before the fix each
    // left an `inline-lowkey-*` marker that kept the CLI busy until restart.
    let dir = markerDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let starter = TakeStarter()
    for press in 1...4 {
      let outcome = starter.start(marker: {
        TakeMarker.create(directory: dir, takeId: "press-\(press)", phase: .recording)
      }, capture: { () -> Double in
        raiseAVAudioEngineAssertion()
        return 0
      })
      guard case .failed(let error) = outcome else {
        Issue.record("press \(press): expected .failed, got \(outcome)")
        continue
      }
      #expect((error as? ObjCException)?.name == "com.apple.coreaudio.avfaudio")
      #expect(!starter.isStarting)
    }
    #expect(markers(in: dir).isEmpty)
  }

  @Test func aSwiftErrorAlsoRemovesTheMarker() {
    let dir = markerDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let outcome = TakeStarter().start(marker: {
      TakeMarker.create(directory: dir, takeId: "t", phase: .recording)
    }, capture: { () -> Double in throw CaptureFailed() })
    guard case .failed(let error) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(error as? CaptureFailed == CaptureFailed())
    #expect(markers(in: dir).isEmpty)
  }

  @Test func aStartedTakeKeepsItsMarker() throws {
    let dir = markerDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let outcome = TakeStarter().start(marker: {
      TakeMarker.create(directory: dir, takeId: "t", phase: .recording)
    }, capture: { 12.5 })
    guard case .started(let engineMs, let marker) = outcome else {
      Issue.record("expected .started, got \(outcome)")
      return
    }
    #expect(engineMs == 12.5)
    #expect(try #require(marker).phase == .recording)
    #expect(markers(in: dir) == ["inline-lowkey-t"])
  }

  @Test func aPressDuringAStartIsRefused() {
    // A nested run loop inside the engine start can deliver another hotkey
    // press: it must not stack a second start (or a second marker).
    let dir = markerDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let starter = TakeStarter()
    var inner: TakeStarter.Outcome<Double>?
    var markersMade = 0
    let outer = starter.start(marker: {
      markersMade += 1
      return TakeMarker.create(directory: dir, takeId: "outer", phase: .recording)
    }, capture: { () -> Double in
      #expect(starter.isStarting)
      inner = starter.start(marker: {
        markersMade += 1
        return TakeMarker.create(directory: dir, takeId: "inner", phase: .recording)
      }, capture: { 1 })
      return 2
    })
    guard case .busy? = inner else {
      Issue.record("expected the nested press to be refused, got \(String(describing: inner))")
      return
    }
    guard case .started(2, _) = outer else {
      Issue.record("expected the first start to finish, got \(outer)")
      return
    }
    #expect(markersMade == 1)
    #expect(markers(in: dir) == ["inline-lowkey-outer"])
    #expect(!starter.isStarting)
  }
}

struct RetryOnceTests {
  @Test func recoversOnceThenSucceeds() throws {
    var attempts = 0
    var recovered: [String] = []
    let value = try RetryOnce.run({ () -> Int in
      attempts += 1
      if attempts == 1 { throw ObjCException(name: "stale", reason: "engine") }
      return 7
    }, recover: { recovered.append(($0 as? ObjCException)?.name ?? "?") })
    #expect(value == 7)
    #expect(attempts == 2)
    #expect(recovered == ["stale"])
  }

  @Test func theSecondFailureIsThrown() {
    var attempts = 0
    var recoveries = 0
    #expect(throws: CaptureFailed()) {
      try RetryOnce.run({ () -> Int in
        attempts += 1
        throw CaptureFailed()
      }, recover: { _ in recoveries += 1 })
    }
    #expect(attempts == 2)
    #expect(recoveries == 1)
  }

  @Test func noRecoveryWhenTheFirstAttemptWorks() throws {
    var recoveries = 0
    #expect(try RetryOnce.run({ 1 }, recover: { _ in recoveries += 1 }) == 1)
    #expect(recoveries == 0)
  }
}

struct OneShotTests {
  @Test func firesOnceAcrossThreads() {
    let shot = OneShot()
    let fired = Locked(0)
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      if shot.fire() { fired.update { $0 += 1 } }
    }
    #expect(fired.value == 1)
    #expect(!shot.fire())
  }

  @Test func cancelBeatsALateFire() {
    let shot = OneShot()
    shot.cancel()
    #expect(!shot.fire())
  }
}

private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
