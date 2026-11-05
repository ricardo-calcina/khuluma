import AVFoundation
import CoreAudio
import Foundation
import KhulumaCore

/// Captures the chosen input device (or the system default) with
/// AVAudioEngine and converts it to 16 kHz mono Float32 in memory.
///
/// The engine is prepared at launch and started per take, so the macOS
/// mic-in-use indicator is only on while recording. When the input device
/// changes, the engine is replaced by a fresh one for the new device: a
/// stale engine raises an Objective-C exception at the next start. A chosen
/// device is set on a fresh engine's input unit before prepare; a changed
/// choice rebuilds the engine while idle and never touches a take.
final class AudioRecorder {
  private var engine = AVAudioEngine()
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
  /// Called on the main queue when the input device changes mid-take.
  var onConfigurationChange: (() -> Void)?
  /// The chosen input's UID; nil follows the system default. Read on the main thread.
  var preferredInputUID: () -> String? = { nil }
  /// The device set on the current engine; nil when it follows the system default.
  private var engineDevice: AudioDeviceID?
  /// The input the current take records from, for the take's log line.
  private(set) var inputName = "no input"
  /// Checked once the take ends, off the stop path.
  private var choiceChangedDuringTake = false

  init() {
    observeConfiguration()
  }

  private func observeConfiguration() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.configurationChanged()
    }
  }

  private func configurationChanged() {
    needsRebuild = true
    if isRecording {
      // The engine stops on a device switch; the take is stopped (keeping
      // what was captured) and the engine rebuilt after it.
      Log.write("audio: input configuration changed mid-take (device switch)")
      onConfigurationChange?()
      return
    }
    Log.write("audio: input configuration changed while idle (device switch)")
    // Switches come in bursts (plug-in, then the default input moves):
    // rebuild once they settle. A press before then rebuilds in start().
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.needsRebuild, !self.isRecording else { return }
      self.rebuild(reason: "input changed while idle")
    }
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
    Log.write("audio: input is \(prepareEngine())")
  }

  /// Instantiates the input graph early. Returns the input, for the log.
  private func prepareEngine(useChoice: Bool = true) -> String {
    let engine = self.engine
    let device = useChoice ? selectDevice(on: engine) : nil
    if !useChoice { engineDevice = nil }
    let name = describe(device)
    do {
      let format = try ObjCException.catching { () -> AVAudioFormat in
        let input = engine.inputNode
        engine.prepare()
        return input.inputFormat(forBus: 0)
      }
      return "\(name) (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)"
    } catch {
      return "\(name) (not prepared: \(error.localizedDescription))"
    }
  }

  /// The chosen device if it is connected; nil means the system default.
  private func wantedDevice() -> AudioDeviceID? {
    preferredInputUID().flatMap { AudioInputDevices.deviceID(uid: $0) }
  }

  /// Points a fresh engine's input unit at the chosen device. Anything that
  /// fails leaves the engine on the system default: a take never fails
  /// because of this preference.
  private func selectDevice(on engine: AVAudioEngine) -> AudioDeviceID? {
    engineDevice = nil
    guard let uid = preferredInputUID() else { return nil }
    guard var device = AudioInputDevices.deviceID(uid: uid) else {
      Log.write("audio: chosen microphone \(uid) isn't connected; using the system default")
      return nil
    }
    let status = (try? ObjCException.catching { () -> OSStatus in
      guard let unit = engine.inputNode.audioUnit else { return OSStatus(kAudioUnitErr_Uninitialized) }
      return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }) ?? OSStatus(kAudioUnitErr_InvalidProperty)
    guard status == noErr else {
      Log.write("audio: could not select \(AudioInputDevices.name(of: device)) (OSStatus \(status)); using the system default")
      return nil
    }
    engineDevice = device
    return device
  }

  private func describe(_ device: AudioDeviceID?) -> String {
    if let device { return AudioInputDevices.name(of: device) }
    return AudioInputDevices.defaultInputID().map { "\(AudioInputDevices.name(of: $0)) (system default)" } ?? "no default input"
  }

  /// The chosen microphone or the connected inputs changed: rebuild while
  /// idle if the engine is on the wrong device. A take is never touched;
  /// it ends on its device and the next one uses the new choice.
  func inputChoiceChanged() {
    guard !isRecording else { choiceChangedDuringTake = true; return }
    choiceChangedDuringTake = false
    if wantedDevice() != engineDevice { rebuild(reason: "microphone choice changed") }
  }

  /// Replaces the engine with a fresh one for the chosen or default input.
  private func rebuild(reason: String, useChoice: Bool = true) {
    let old = engine
    _ = try? ObjCException.catching {
      old.stop()
      old.reset()
    }
    engine = AVAudioEngine()
    observeConfiguration()
    needsRebuild = false
    choiceChangedDuringTake = false
    Log.write("audio: \(reason); rebuilt the engine for \(prepareEngine(useChoice: useChoice))")
  }

  /// Starts capture. Returns how long engine start took, in ms. A failure
  /// (including an exception from AVAudioEngine) is retried once on a
  /// fresh engine, then thrown. `onFirstAudio` runs on the audio thread
  /// when the first buffer arrives: the moment speech is really captured.
  @discardableResult
  func start(onFirstAudio: (() -> Void)? = nil) throws -> Double {
    guard !isRecording else { return 0 }
    if needsRebuild { rebuild(reason: "input changed since the last take") }
    else if wantedDevice() != engineDevice { rebuild(reason: "microphone choice changed since the last take") }
    return try RetryOnce.run({ try startEngine(onFirstAudio: onFirstAudio) }, recover: { error in
      Log.write("audio: could not start capture (\(error.localizedDescription)); retrying once on a fresh engine")
      // A chosen device that won't start must not cost the take.
      if engineDevice != nil {
        Log.write("audio: falling back to the system default for this take")
        rebuild(reason: "start failed", useChoice: false)
      } else {
        rebuild(reason: "start failed")
      }
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
    inputName = describe(engineDevice)
    return elapsed
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
      RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.inputChoiceChanged() }
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
