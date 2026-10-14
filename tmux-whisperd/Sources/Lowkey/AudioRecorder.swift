import AVFoundation
import CoreAudio
import Foundation
import LowkeyCore

/// Captures the default input device with AVAudioEngine and converts it to
/// 16 kHz mono Float32 in memory.
///
/// The engine is prepared at launch and started per take, so the macOS
/// mic-in-use indicator is only on while recording. When the input device
/// changes, the engine is replaced by a fresh one for the new device: a
/// stale engine raises an Objective-C exception at the next start.
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
  private func prepareEngine() -> String {
    let engine = self.engine
    do {
      let format = try ObjCException.catching { () -> AVAudioFormat in
        let input = engine.inputNode
        engine.prepare()
        return input.inputFormat(forBus: 0)
      }
      return "\(Self.defaultInputName()) (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)"
    } catch {
      return "\(Self.defaultInputName()) (not prepared: \(error.localizedDescription))"
    }
  }

  /// Replaces the engine with a fresh one for the current default input.
  private func rebuild(reason: String) {
    let old = engine
    _ = try? ObjCException.catching {
      old.stop()
      old.reset()
    }
    engine = AVAudioEngine()
    observeConfiguration()
    needsRebuild = false
    Log.write("audio: \(reason); rebuilt the engine for \(prepareEngine())")
  }

  /// Starts capture. Returns how long engine start took, in ms. A failure
  /// (including an exception from AVAudioEngine) is retried once on a
  /// fresh engine, then thrown. `onFirstAudio` runs on the audio thread
  /// when the first buffer arrives: the moment speech is really captured.
  @discardableResult
  func start(onFirstAudio: (() -> Void)? = nil) throws -> Double {
    guard !isRecording else { return 0 }
    if needsRebuild { rebuild(reason: "input changed since the last take") }
    return try RetryOnce.run({ try startEngine(onFirstAudio: onFirstAudio) }, recover: { error in
      Log.write("audio: could not start capture (\(error.localizedDescription)); retrying once on a fresh engine")
      rebuild(reason: "start failed")
    })
  }

  private func startEngine(onFirstAudio: (() -> Void)?) throws -> Double {
    let engine = self.engine
    let inputFormat = try ObjCException.catching { engine.inputNode.outputFormat(forBus: 0) }
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw NSError(domain: "Lowkey", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input device available"])
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
    return monotonicMs() - started
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

  /// The default input device's name, for the log.
  private static func defaultInputName() -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return "no default input" }
    address.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else {
      return "input device \(device)"
    }
    return name.takeRetainedValue() as String
  }
}
