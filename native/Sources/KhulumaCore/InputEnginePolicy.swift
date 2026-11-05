/// What an input engine was built for. `unitDevice` is what its input unit
/// reported after any selection: the chosen device when pinned, but
/// AVAudioEngine's own aggregate when following the default (verified on
/// macOS 27), so the logical `target` is kept separately: the chosen device,
/// or the system default at build time.
public struct InputEngineBuild: Equatable, Sendable {
  public var generation: Int
  public var unitDevice: UInt32?
  public var target: UInt32?
  public var sampleRate: Double
  public var channels: UInt32

  public init(generation: Int, unitDevice: UInt32?, target: UInt32?, sampleRate: Double, channels: UInt32) {
    self.generation = generation
    self.unitDevice = unitDevice
    self.target = target
    self.sampleRate = sampleRate
    self.channels = channels
  }
}

/// The engine as seen when a configuration-change notification arrives.
public struct InputEngineObservation: Equatable, Sendable {
  public var isRunning: Bool
  /// The device the input unit reports now.
  public var unitDevice: UInt32?
  /// Whether the engine's target device still exists.
  public var targetAlive: Bool
  /// The device the recorder intends to use now: the chosen one if usable,
  /// otherwise the current system default.
  public var wanted: UInt32?
  public var sampleRate: Double
  public var channels: UInt32

  public init(isRunning: Bool, unitDevice: UInt32?, targetAlive: Bool, wanted: UInt32?,
              sampleRate: Double, channels: UInt32) {
    self.isRunning = isRunning
    self.unitDevice = unitDevice
    self.targetAlive = targetAlive
    self.wanted = wanted
    self.sampleRate = sampleRate
    self.channels = channels
  }
}

/// Decisions for the recorder's engine. Never losing a take comes first: a
/// take stops only when capture really stopped or moved device, and a
/// notification the recorder caused itself (selecting a device) is ignored,
/// so rebuilds can't loop.
public enum InputEnginePolicy {
  public enum Change: Equatable, Sendable {
    case ignore(String)
    /// Capture is broken: end the take, keeping what was captured.
    case stopTake(String)
    /// Replace the engine: now (debounced) when idle, after the take otherwise.
    case rebuild(String)
  }

  public static func configurationChanged(notifiedGeneration: Int, built: InputEngineBuild,
                                          observed: InputEngineObservation, recording: Bool) -> Change {
    guard notifiedGeneration == built.generation else { return .ignore("late notice from a replaced engine") }
    let moved = observed.unitDevice != built.unitDevice || !observed.targetAlive
    let reformatted = observed.sampleRate != built.sampleRate || observed.channels != built.channels
    let stale = observed.wanted != built.target
    if recording {
      if !observed.isRunning { return .stopTake("capture stopped") }
      if moved { return .stopTake(observed.targetAlive ? "input device changed" : "input device disappeared") }
      if reformatted || stale {
        return .rebuild(reformatted ? "input format changed" : "a different input is wanted")
      }
      return .ignore("capture still running on the same device")
    }
    if moved { return .rebuild(observed.targetAlive ? "input device changed" : "input device disappeared") }
    if reformatted { return .rebuild("input format changed") }
    if stale { return .rebuild("a different input is wanted") }
    return .ignore("same device and format (the engine's own device selection)")
  }

  /// Before a take: rebuild if a change was flagged or the engine is on
  /// another device than the one wanted now.
  public static func rebuildBeforeTake(flagged: Bool, built: InputEngineBuild, wanted: UInt32?) -> Bool {
    flagged || built.target != wanted
  }

  public enum Selection: Equatable, Sendable {
    /// No device chosen (or it isn't connected): the system default.
    case followDefault
    case accepted
    /// Discard this engine and use a fresh one on the system default.
    case fallBack(String)
  }

  /// Checks a device selection against what the input unit reports back.
  /// `setStatus` is the OSStatus of setting the device (nil if not tried).
  public static func selection(requested: UInt32?, setStatus: Int32?, actual: UInt32?) -> Selection {
    guard let requested else { return .followDefault }
    guard let setStatus else { return .fallBack("the device was not set") }
    guard setStatus == 0 else { return .fallBack("setting the device failed (OSStatus \(setStatus))") }
    guard let actual else { return .fallBack("the engine reports no device") }
    guard actual == requested else { return .fallBack("the engine reports device \(actual), not \(requested)") }
    return .accepted
  }
}
