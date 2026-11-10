import CoreAudio
import Foundation
import KhulumaCore

/// Silences the system default output while a take records (Settings ›
/// Dictation › Mute other audio). What it applied is kept in defaults, so a
/// crash can't leave the Mac silent: `restorePending()` at launch puts it
/// back by the same rule. Restore always targets the device that was muted,
/// never whatever happens to be default then.
final class OutputMuter {
  private struct Applied: Codable {
    enum Method: String, Codable { case mute, volume }
    var deviceID: UInt32
    var uid: String
    var method: Method
    /// The volume to put back (method .volume only).
    var volume: Float
  }

  private let defaults: UserDefaults
  private static let recordKey = "outputMuteApplied"
  private var applied: Applied?

  init(defaults: UserDefaults = AppRuntimePaths.defaults) {
    self.defaults = defaults
  }

  /// Mutes the default output per `OutputMutePolicy`. One mute at a time; a
  /// second call while muted does nothing.
  func mute() {
    guard applied == nil, persisted() == nil else { return }
    guard let device = Self.defaultOutput(), let uid = Self.uid(of: device) else {
      Log.write("mute: skipped (no default output device)")
      return
    }
    var muteAddress = Address.mute
    let muteSettable = Self.isSettable(device, &muteAddress)
    let muted = Self.getUInt32(device, &muteAddress) == 1
    var volumeAddress = Self.volumeAddress(for: device)
    let volumeSettable = volumeAddress != nil
    let volume = volumeAddress != nil ? Self.getFloat(device, &volumeAddress!) : 0
    switch OutputMutePolicy.plan(muteSettable: muteSettable, currentlyMuted: muted,
                                 volumeSettable: volumeSettable, currentVolume: volume) {
    case .none(let reason):
      Log.write("mute: skipped (\(reason))")
    case .setMute:
      guard Self.setUInt32(device, &muteAddress, 1) else {
        Log.write("mute: could not mute \(uid)")
        return
      }
      save(Applied(deviceID: device, uid: uid, method: .mute, volume: volume))
      Log.write("mute: muted \(uid)")
    case .zeroVolume(let restore):
      guard var address = volumeAddress, Self.setFloat(device, &address, 0) else {
        Log.write("mute: could not zero the volume of \(uid)")
        return
      }
      save(Applied(deviceID: device, uid: uid, method: .volume, volume: restore))
      Log.write("mute: zeroed \(uid) (was \(String(format: "%.2f", restore)))")
    }
  }

  /// Puts the device's sound back, unless the user changed it meanwhile.
  /// Idempotent.
  func restore() {
    guard let applied = take() else { return }
    restore(applied)
  }

  /// At launch: a previous run that crashed mid-take may have left the
  /// output muted. Replay the same restore rule, then drop the record.
  func restorePending() {
    guard applied == nil, let record = takePersisted() else { return }
    restore(record)
  }

  private func restore(_ applied: Applied) {
    guard let device = Self.device(uid: applied.uid) ?? Self.device(id: applied.deviceID) else {
      Log.write("mute: the muted device (\(applied.uid)) is gone; nothing to restore")
      return
    }
    var muteAddress = Address.mute
    let nowMuted = Self.getUInt32(device, &muteAddress) == 1
    var volumeAddress = Self.volumeAddress(for: device)
    let nowVolume = volumeAddress != nil ? Self.getFloat(device, &volumeAddress!) : 0
    let plan: OutputMutePolicy.Plan = applied.method == .mute ? .setMute : .zeroVolume(restore: applied.volume)
    guard OutputMutePolicy.shouldRestore(applied: plan, nowMuted: nowMuted, nowVolume: nowVolume) else {
      Log.write("mute: left \(applied.uid) alone (changed while muted)")
      return
    }
    switch applied.method {
    case .mute:
      guard Self.setUInt32(device, &muteAddress, 0) else {
        Log.write("mute: could not unmute \(applied.uid)")
        return
      }
    case .volume:
      guard var address = volumeAddress, Self.setFloat(device, &address, applied.volume) else {
        Log.write("mute: could not restore the volume of \(applied.uid)")
        return
      }
    }
    Log.write("mute: restored \(applied.uid)")
  }

  // MARK: Record

  private func save(_ record: Applied) {
    applied = record
    defaults.set(try? JSONEncoder().encode(record), forKey: Self.recordKey)
  }

  /// Clears the in-memory and persisted record, returning what was applied.
  private func take() -> Applied? {
    defer { defaults.removeObject(forKey: Self.recordKey) }
    if let applied { self.applied = nil; return applied }
    return takePersisted()
  }

  private func takePersisted() -> Applied? {
    defer { defaults.removeObject(forKey: Self.recordKey) }
    return persisted()
  }

  private func persisted() -> Applied? {
    guard let data = defaults.data(forKey: Self.recordKey) else { return nil }
    return try? JSONDecoder().decode(Applied.self, from: data)
  }

  // MARK: CoreAudio

  private enum Address {
    static var mute = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  /// The main-element volume scalar, else the virtual main volume.
  private static func volumeAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
    var scalar = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    if isSettable(device, &scalar) { return scalar }
    // The virtual main volume ('vvol'), for devices without a per-channel
    // volume (the constant isn't in this SDK's Swift overlay).
    var virtual = AudioObjectPropertyAddress(
      mSelector: AudioObjectPropertySelector(0x7676_6F6C),
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    return isSettable(device, &virtual) ? virtual : nil
  }

  private static func defaultOutput() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          device != kAudioDeviceUnknown else { return nil }
    return device
  }

  private static func uid(of device: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
    return uid?.takeUnretainedValue() as String?
  }

  /// Every output device, for finding the remembered one by UID.
  private static func allDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
  }

  private static func device(uid: String) -> AudioDeviceID? {
    allDevices().first { self.uid(of: $0) == uid }
  }

  private static func device(id: AudioDeviceID) -> AudioDeviceID? {
    allDevices().contains(id) ? id : nil
  }

  private static func isSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
    var settable = DarwinBoolean(false)
    return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
  }

  private static func getUInt32(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> UInt32 {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
    return value
  }

  private static func getFloat(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Float {
    var value: Float = 0
    var size = UInt32(MemoryLayout<Float>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
    return value
  }

  private static func setUInt32(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
    var copy = value
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &copy) == noErr
  }

  private static func setFloat(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress, _ value: Float) -> Bool {
    var copy = value
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &copy) == noErr
  }
}
