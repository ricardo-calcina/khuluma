import AVFoundation
import CoreAudio
import Foundation
import KhulumaCore

/// Captures the chosen input device (or the system default) with
/// AVAudioEngine and converts it to 16 kHz mono Float32 in memory.
///
/// The engine is prepared at launch and started per take, so the macOS
/// mic-in-use indicator is only on while recording. When the input changes,
/// the engine is replaced by a fresh one: a stale engine raises an
/// Objective-C exception at the next start. A chosen device is set on a
/// fresh engine's input unit before prepare and read back; if it doesn't
/// hold, that engine is discarded for an untouched one on the system
/// default. Each engine has a generation, so late notices from replaced
/// engines and the notice our own selection posts are ignored
/// (`InputEnginePolicy`). Never losing a take comes first.
final class AudioRecorder {
  private var engine = AVAudioEngine()
  /// Bumped for every engine; configuration notices carry the one they came from.
  private var generation = 0
  /// What the current engine was built for, read back from its input unit.
  private var built = InputEngineBuild(generation: 0, unitDevice: nil, target: nil, sampleRate: 0, channels: 0)
  /// The chosen device's UID when the current engine is pinned to it.
  private var pinnedUID: String?
  /// Why the current engine isn't on the chosen device, for the take log.
  private var fallbackReason: String?
  /// A chosen device that failed: takes use the system default until the
  /// choice or the device list changes. Reported to the menu.
  private var failedUID: String? {
    didSet { if failedUID != oldValue { onFallbackChange(failedUID) } }
  }
  private var configurationObserver: NSObjectProtocol?
  private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  private let lock = NSLock()
  private var samples: [Float] = []
  private var converter: AVAudioConverter?
  private var firstBufferAt: Double?
  /// Called once, on the audio thread, when the take's first buffer arrives.
  private var onFirstAudio: (() -> Void)?
  private(set) var isRecording = false
  /// The input changed: rebuild the engine before the next take.
  private var needsRebuild = false
  /// Called on the main queue when capture breaks mid-take (device switch).
  var onConfigurationChange: (() -> Void)?
  /// The chosen input (nil = System Default). Read on the main thread.
  var preferredInput: () -> AudioInput? = { nil }
  /// The chosen device failed (its UID) or is usable again (nil). Main thread.
  var onFallbackChange: (String?) -> Void = { _ in }
  /// The input the current take records from, for the take's start line.
  private(set) var inputName = "no input"
  /// Checked once the take ends, off the stop path.
  private var choiceChangedDuringTake = false

  private func observeConfiguration() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    let generation = self.generation
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.configurationChanged(generation: generation)
    }
  }

  private func configurationChanged(generation: Int) {
    let change = InputEnginePolicy.configurationChanged(notifiedGeneration: generation, built: built,
                                                        observed: observe(), recording: isRecording)
    switch change {
    case .ignore(let why):
      Log.write("audio: configuration notice ignored (\(why))")
    case .stopTake(let why):
      // The take is stopped (keeping what was captured) and the engine rebuilt after it.
      needsRebuild = true
      Log.write("audio: \(why) mid-take; stopping the take")
      onConfigurationChange?()
    case .rebuild(let why):
      needsRebuild = true
      if isRecording {
        Log.write("audio: \(why) mid-take; capture continues, the engine is rebuilt after the take")
        return
      }
      Log.write("audio: \(why) while idle")
      // Switches come in bursts (plug-in, then the default input moves):
      // rebuild once they settle. A press before then rebuilds in start().
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self, self.needsRebuild, !self.isRecording else { return }
        self.rebuild(reason: "input changed while idle")
      }
    }
  }

  /// The current engine as it is now, for `InputEnginePolicy`.
  private func observe() -> InputEngineObservation {
    let engine = self.engine
    let format = try? ObjCException.catching { engine.inputNode.inputFormat(forBus: 0) }
    return InputEngineObservation(
      isRunning: engine.isRunning, unitDevice: Self.unitDevice(of: engine),
      targetAlive: built.target.map { AudioInputDevices.isAlive($0) } ?? true,
      wanted: intended().device, sampleRate: format?.sampleRate ?? 0, channels: format?.channelCount ?? 0)
  }

  /// The device the next take should use: the chosen one if connected and
  /// not failed, otherwise the system default.
  private func intended() -> (device: AudioDeviceID?, uid: String?) {
    if let uid = preferredInput()?.uid, uid != failedUID, let device = AudioInputDevices.deviceID(uid: uid) {
      return (device, uid)
    }
    return (AudioInputDevices.defaultInputID(), nil)
  }

  /// The device the input unit reports (AVAudioEngine's aggregate when following the default).
  private static func unitDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
    try? ObjCException.catching { () -> AudioDeviceID? in
      guard let unit = engine.inputNode.audioUnit else { return nil }
      var device = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, &size) == noErr, device != kAudioObjectUnknown else { return nil }
      return device
    } ?? nil
  }

  static func requestPermission(_ completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default:
      completion(false)
    }
  }

  func prepare() {
    retire(engine)
    Log.write("audio: input is \(build())")
  }

  private func retire(_ old: AVAudioEngine) {
    _ = try? ObjCException.catching {
      old.stop()
      old.reset()
    }
  }

  /// Replaces the engine with a fresh one for the intended input.
  private func rebuild(reason: String) {
    retire(engine)
    needsRebuild = false
    choiceChangedDuringTake = false
    Log.write("audio: \(reason); rebuilt the engine for \(build())")
  }

  /// Makes and prepares a fresh engine. A chosen device is set and read
  /// back first; if it doesn't hold, the engine is discarded and an
  /// untouched one follows the system default. Returns the input, for the log.
  private func build(useChoice: Bool = true) -> String {
    generation += 1
    let engine = AVAudioEngine()
    self.engine = engine
    observeConfiguration()
    let preferred = preferredInput()
    let target: (device: AudioDeviceID?, uid: String?) = useChoice ? intended() : (AudioInputDevices.defaultInputID(), nil)
    var setStatus: Int32?
    if target.uid != nil, var device = target.device {
      setStatus = (try? ObjCException.catching { () -> OSStatus in
        guard let unit = engine.inputNode.audioUnit else { return OSStatus(kAudioUnitErr_Uninitialized) }
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioDeviceID>.size))
      }) ?? OSStatus(kAudioUnitErr_InvalidProperty)
    }
    let requested = target.uid == nil ? nil : target.device
    switch InputEnginePolicy.selection(requested: requested, setStatus: setStatus, actual: Self.unitDevice(of: engine)) {
    case .fallBack(let why):
      let name = preferred?.name ?? target.uid ?? "the chosen microphone"
      Log.write("audio: could not use \(name): \(why); discarding that engine for the system default")
      failedUID = target.uid
      fallbackReason = why
      retire(engine)
      return build(useChoice: false)
    case .accepted:
      pinnedUID = target.uid
      fallbackReason = nil
    case .followDefault:
      pinnedUID = nil
      if let preferred {
        if preferred.uid == failedUID { fallbackReason = fallbackReason ?? "it failed earlier" }
        else { fallbackReason = "\(preferred.name) isn't connected" }
      } else {
        fallbackReason = nil
      }
    }
    var description = describe(unit: Self.unitDevice(of: engine), target: target.device)
    do {
      let format = try ObjCException.catching { () -> AVAudioFormat in
        let input = engine.inputNode
        engine.prepare()
        return input.inputFormat(forBus: 0)
      }
      built = InputEngineBuild(generation: generation, unitDevice: Self.unitDevice(of: engine), target: target.device,
                               sampleRate: format.sampleRate, channels: format.channelCount)
      description += " (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)"
    } catch {
      built = InputEngineBuild(generation: generation, unitDevice: Self.unitDevice(of: engine), target: target.device,
                               sampleRate: 0, channels: 0)
      description += " (not prepared: \(error.localizedDescription))"
    }
    return description
  }

  /// The input by name: the pinned device, or the default this engine follows.
  private func describe(unit: AudioDeviceID?, target: AudioDeviceID?) -> String {
    if pinnedUID != nil, let unit { return AudioInputDevices.name(of: unit) }
    return target.map { "\(AudioInputDevices.name(of: $0)) (system default)" } ?? "no default input"
  }

  /// The chosen microphone or the connected inputs changed: retry a failed
  /// choice and rebuild while idle if the engine is on another input. A take
  /// is never touched; it ends on its device and the next one uses the choice.
  func inputChoiceChanged() {
    failedUID = nil
    guard !isRecording else { choiceChangedDuringTake = true; return }
    rebuildIfStale()
  }

  private func rebuildIfStale() {
    choiceChangedDuringTake = false
    guard InputEnginePolicy.rebuildBeforeTake(flagged: false, built: built, wanted: intended().device) else { return }
    rebuild(reason: "microphone choice changed")
  }

  /// Starts capture. Returns how long engine start took, in ms. A failure
  /// (including an exception from AVAudioEngine) is retried once on a
  /// fresh engine, then thrown; a chosen device that won't start makes the
  /// retry use the system default. `onFirstAudio` runs on the audio thread
  /// when the first buffer arrives: the moment speech is really captured.
  @discardableResult
  func start(onFirstAudio: (() -> Void)? = nil) throws -> Double {
    guard !isRecording else { return 0 }
    if InputEnginePolicy.rebuildBeforeTake(flagged: needsRebuild, built: built, wanted: intended().device) {
      rebuild(reason: needsRebuild ? "input changed since the last take" : "microphone choice changed since the last take")
    }
    return try RetryOnce.run({ try startEngine(onFirstAudio: onFirstAudio) }, recover: { error in
      Log.write("audio: could not start capture (\(error.localizedDescription)); retrying once on a fresh engine")
      if let pinnedUID {
        // The chosen device must not cost the take.
        failedUID = pinnedUID
        fallbackReason = "start failed: \(error.localizedDescription)"
        Log.write("audio: the retry uses the system default")
      }
      rebuild(reason: "start failed")
    })
  }

  private func startEngine(onFirstAudio: (() -> Void)?) throws -> Double {
    let engine = self.engine
    let inputFormat = try ObjCException.catching { engine.inputNode.outputFormat(forBus: 0) }
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw NSError(domain: "Khuluma", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input device available"])
    }
    converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    lock.withLock {
      samples.removeAll(keepingCapacity: true)
      firstBufferAt = nil
      self.onFirstAudio = onFirstAudio
    }

    try ObjCException.catching {
      engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
        self?.append(buffer)
      }
    }
    let started = monotonicMs()
    do {
      try ObjCException.catching { try engine.start() }
    } catch {
      _ = try? ObjCException.catching {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
      }
      throw error
    }
    isRecording = true
    let elapsed = monotonicMs() - started
    noteTakeInput(engine)
    return elapsed
  }

  /// Reads back the device the take really uses and logs requested, actual
  /// and any fallback. A pin that didn't hold can't be fixed mid-take: the
  /// take goes on, and the next one uses the system default.
  private func noteTakeInput(_ engine: AVAudioEngine) {
    let actual = Self.unitDevice(of: engine)
    if let pinnedUID, case .fallBack(let why) = InputEnginePolicy.selection(
      requested: built.target, setStatus: 0, actual: actual) {
      Log.write("audio: the chosen microphone didn't hold after start (\(why)); next take uses the system default")
      failedUID = pinnedUID
      fallbackReason = why
      needsRebuild = true
    }
    // Later notices compare against what is really capturing.
    built.unitDevice = actual
    inputName = describe(unit: actual, target: built.target)
    let requested = preferredInput().map(\.name) ?? "system default"
    Log.write("audio: take input requested=\(requested) actual=\(inputName) fallback=\(fallbackReason ?? "none")")
  }

  /// Stops capture and returns the take.
  func stop() -> [Float] {
    guard isRecording else { return [] }
    let engine = self.engine
    _ = try? ObjCException.catching {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    isRecording = false
    let take = lock.withLock {
      onFirstAudio = nil
      let take = samples
      samples.removeAll(keepingCapacity: false)
      return take
    }
    if needsRebuild { rebuild(reason: "input changed during the take") }
    else if choiceChangedDuringTake {
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        guard let self, !self.isRecording else { return }
        self.rebuildIfStale()
      }
    }
    return take
  }

  /// Monotonic time at which the first audio buffer arrived, if any.
  var firstBufferTime: Double? {
    lock.withLock { firstBufferAt }
  }

  private func append(_ buffer: AVAudioPCMBuffer) {
    guard let converter else { return }
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let channel = output.floatChannelData?[0] else { return }
    let count = Int(output.frameLength)
    let first = lock.withLock { () -> (() -> Void)? in
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
      guard firstBufferAt == nil else { return nil }
      firstBufferAt = monotonicMs()
      defer { onFirstAudio = nil }
      return onFirstAudio
    }
    first?()
  }
}
