import AppKit
import CoreAudio
import Foundation
import KhulumaCore

/// Reads CoreAudio's input devices. Queries are cheap, synchronous and safe
/// on the main thread.
enum AudioInputDevices {
  private static let system = AudioObjectID(kAudioObjectSystemObject)

  /// Connected, visible devices with input streams, in system order.
  static func current() -> AudioInputs {
    let devices = deviceIDs().compactMap { id -> AudioInput? in
      guard hasInput(id), !isHidden(id), !isPrivateAggregate(id),
            let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
      return AudioInput(uid: uid, name: name(of: id))
    }
    return AudioInputs(devices: devices, defaultUID: defaultInputID().flatMap { string($0, kAudioDevicePropertyDeviceUID) })
  }

  /// The connected input device with this UID, if any.
  static func deviceID(uid: String) -> AudioDeviceID? {
    var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
      AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
    }
    guard status == noErr, device != kAudioObjectUnknown, isAlive(device), hasInput(device) else { return nil }
    return device
  }

  static func defaultInputID() -> AudioDeviceID? {
    var address = address(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
  }

  static func name(of device: AudioDeviceID) -> String {
    string(device, kAudioObjectPropertyName) ?? "input device \(device)"
  }

  /// Opens System Settings at Sound → Input.
  static func openSoundSettings() {
    let pane = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!
    if !NSWorkspace.shared.open(pane) {
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
    }
  }

  private static func deviceIDs() -> [AudioDeviceID] {
    var address = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
  }

  private static func hasInput(_ device: AudioDeviceID) -> Bool {
    var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
  }

  private static func isHidden(_ device: AudioDeviceID) -> Bool { uint32(device, kAudioDevicePropertyIsHidden) == 1 }

  /// AVAudioEngine makes a private aggregate (CADefaultDeviceAggregate-…)
  /// to follow the default input; it isn't a microphone to offer.
  private static func isPrivateAggregate(_ device: AudioDeviceID) -> Bool {
    guard uint32(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate else { return false }
    var address = address(kAudioAggregateDevicePropertyComposition)
    var value: Unmanaged<CFDictionary>?
    var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
       let composition = value?.takeRetainedValue() as? [String: Any],
       (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true {
      return true
    }
    return string(device, kAudioDevicePropertyDeviceUID)?.hasPrefix("CADefaultDeviceAggregate") == true
  }
  static func isAlive(_ device: AudioDeviceID) -> Bool { uint32(device, kAudioDevicePropertyDeviceIsAlive) != 0 }

  private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
  }

  private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func address(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
}

/// Reports the input list whenever devices come and go or the system default
/// input changes. Delivery uses common run loop modes, so an open menu
/// updates too.
final class AudioInputMonitor {
  private let onChange: (AudioInputs) -> Void
  private let queue = DispatchQueue(label: "khuluma.audio-inputs")
  private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var pending = false

  init(onChange: @escaping (AudioInputs) -> Void) {
    self.onChange = onChange
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
      var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
      if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
        listeners.append((address, block))
      } else {
        Log.write("audio: could not watch input devices (selector \(selector))")
      }
    }
    onChange(AudioInputDevices.current())
  }

  deinit {
    for (address, block) in listeners {
      var address = address
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
  }

  /// Called on `queue`. Changes arrive in bursts; read once per burst.
  private func changed() {
    guard !pending else { return }
    pending = true
    queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
      self.pending = false
      let inputs = AudioInputDevices.current()
      RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.onChange(inputs) }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }
}
