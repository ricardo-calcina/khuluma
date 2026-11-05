/// The input an engine is meant for: a pinned device (the chosen one), or
/// following the system default (with the default it resolved to). The mode
/// matters on its own: following A and pinned to A behave differently when
/// the default later moves.
public struct InputTarget: Equatable, Sendable {
  public var device: UInt32?
  public var pinned: Bool

  public init(device: UInt32?, pinned: Bool) {
    self.device = device
    self.pinned = pinned
  }

  public static func pinned(_ device: UInt32) -> InputTarget { InputTarget(device: device, pinned: true) }
  public static func followingDefault(_ device: UInt32?) -> InputTarget { InputTarget(device: device, pinned: false) }
}

/// CoreAudio readings mapped to decisions; a failed query (nil) is never
/// taken as good news.
public enum CoreAudioReading {
  /// `kAudioDevicePropertyDeviceIsAlive`: alive only when it reads exactly 1.
  /// A removed device often can't be queried at all.
  public static func isAlive(_ value: UInt32?) -> Bool { value == 1 }
}

/// What an input engine was built for. `unitDevice` is what its input unit
/// reported after any selection: the chosen device when pinned, but
/// AVAudioEngine's own aggregate when following the default (verified on
/// macOS 27), so the logical `target` is kept separately: the chosen device,
/// or the system default at build time.
public struct InputEngineBuild: Equatable, Sendable {
  public var generation: Int
  public var unitDevice: UInt32?
  public var target: InputTarget
  public var sampleRate: Double
  public var channels: UInt32
  /// Following the default: the system default input read right after the
  /// take started (the aggregate keeps its ID when its input moves).
  public var defaultAtStart: UInt32?

  public init(generation: Int, unitDevice: UInt32?, target: InputTarget, sampleRate: Double, channels: UInt32,
              defaultAtStart: UInt32? = nil) {
    self.generation = generation
    self.unitDevice = unitDevice
    self.target = target
    self.sampleRate = sampleRate
    self.channels = channels
    self.defaultAtStart = defaultAtStart
  }
}

/// The engine as seen when a configuration-change notification arrives.
public struct InputEngineObservation: Equatable, Sendable {
  public var isRunning: Bool
  /// The device the input unit reports now.
  public var unitDevice: UInt32?
  /// Whether the engine's target device still exists.
  public var targetAlive: Bool
  /// What the recorder intends now: the chosen device pinned if usable,
  /// otherwise following the current system default.
  public var wanted: InputTarget
  /// The system default input now.
  public var systemDefault: UInt32?
  public var sampleRate: Double
  public var channels: UInt32

  public init(isRunning: Bool, unitDevice: UInt32?, targetAlive: Bool, wanted: InputTarget,
              systemDefault: UInt32? = nil, sampleRate: Double, channels: UInt32) {
    self.isRunning = isRunning
    self.unitDevice = unitDevice
    self.targetAlive = targetAlive
    self.wanted = wanted
    self.systemDefault = systemDefault
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
    if recording, !built.target.pinned {
      // Following the default, as before pinning existed: the aggregate keeps
      // its ID and format when its input moves, so compare the default itself.
      if !observed.isRunning { return .stopTake("capture stopped") }
      if observed.systemDefault != built.defaultAtStart { return .stopTake("system default input changed") }
      return .ignore("capture still running on the same default input")
    }
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
  /// another device, or in another mode, than the one wanted now.
  public static func rebuildBeforeTake(flagged: Bool, built: InputEngineBuild, wanted: InputTarget) -> Bool {
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
