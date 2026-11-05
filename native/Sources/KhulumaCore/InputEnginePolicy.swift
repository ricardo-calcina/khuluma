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

/// A capture format as AVAudioFormat describes it. Equality is the whole
/// format (rate, channels, sample format, interleaving, channel layout);
/// `sameShape` compares only rate and channels.
public struct CaptureFormat: Equatable, Sendable, CustomStringConvertible {
  public var sampleRate: Double
  public var channels: UInt32
  /// `AVAudioCommonFormat` raw value (0 = other, such as packed integers).
  public var commonFormat: UInt
  public var interleaved: Bool
  /// The channel layout tag, if the format has a layout.
  public var layoutTag: UInt32?

  public init(sampleRate: Double, channels: UInt32, commonFormat: UInt = 1, interleaved: Bool = false,
              layoutTag: UInt32? = nil) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.commonFormat = commonFormat
    self.interleaved = interleaved
    self.layoutTag = layoutTag
  }

  public var isUsable: Bool { sampleRate > 0 && channels > 0 }
  public func sameShape(_ other: CaptureFormat) -> Bool { sampleRate == other.sampleRate && channels == other.channels }
  public var description: String {
    var text = "\(Int(sampleRate)) Hz, \(channels) ch"
    if commonFormat != 1 { text += ", sample format \(commonFormat)" }
    if interleaved { text += ", interleaved" }
    return text
  }
}

/// How capture starts and recovers. Continuity (iPhone), and some Bluetooth
/// and USB microphones, settle their hardware format only once activated, so
/// the format read when the engine was prepared can be stale by the time the
/// tap goes on; AVAudioEngine then refuses the tap
/// (`format.sampleRate == inputHWFormat.sampleRate`).
public enum CaptureStartPolicy {
  public enum TapSource: Equatable, Sendable {
    /// The input node's output format object, exactly as before.
    case node
    /// The input's hardware format object (`inputFormat(forBus: 0)`).
    case hardware
  }

  /// Which format object the tap uses, from both read right before the tap
  /// is installed. When they agree on rate and channels the node's own
  /// format is used, so the ordinary path is unchanged; when they differ the
  /// node's format is the stale one. Nil: nothing usable to tap.
  public static func tapSource(hardware: CaptureFormat?, node: CaptureFormat?) -> TapSource? {
    let nodeUsable = node?.isUsable == true, hardwareUsable = hardware?.isUsable == true
    if let hardware, let node, nodeUsable, hardwareUsable, node.sameShape(hardware) { return .node }
    if hardwareUsable { return .hardware }
    return nodeUsable ? .node : nil
  }

  /// The 16 kHz converter is built for the tap's format and replaced when
  /// the buffers that arrive differ from it in any way.
  public static func needsNewConverter(builtFor: CaptureFormat?, buffer: CaptureFormat) -> Bool {
    builtFor != buffer
  }

  public enum Recovery: Equatable, Sendable {
    /// A fresh engine on the same chosen device, formats read again.
    case sameDevice
    /// The chosen device won't start: a fresh engine on the system default.
    case systemDefault
    /// A fresh engine on the system default (it was already following it).
    case freshEngine
  }

  /// What to do after the `failures`-th failed start, or nil to give up.
  /// A chosen device gets one more try before the take falls back to the
  /// system default; the default itself gets one fresh retry, as before.
  public static func recovery(afterFailure failures: Int, pinned: Bool) -> Recovery? {
    switch (pinned, failures) {
    case (true, 1): return .sameDevice
    case (true, 2): return .systemDefault
    case (false, 1): return .freshEngine
    default: return nil
    }
  }
}
