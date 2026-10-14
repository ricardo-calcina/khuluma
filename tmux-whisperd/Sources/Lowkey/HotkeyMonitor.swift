import Carbon.HIToolbox
import Foundation
import LowkeyCore

/// A system-wide hotkey via Carbon `RegisterEventHotKey`, which needs no
/// Accessibility or Input Monitoring permission. Several monitors can live
/// side by side (the toggle and the cancel key): each handles only presses
/// of its own hot keys, told apart by `signature`.
final class HotkeyMonitor {
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let action: () -> Void
  private let signature: OSType

  init(signature: OSType = 0x4C4F574B /* 'LOWK' */, action: @escaping () -> Void) {
    self.signature = signature
    self.action = action
  }

  deinit {
    unregister()
  }

  /// The binding in effect, if any.
  private(set) var binding: HotkeySpec?
  private var nextID: UInt32 = 0

  /// Binds `spec`. The new hot key is registered before the old one is
  /// released, so if it's unavailable (taken by another app) the old one
  /// keeps working and this throws.
  func register(_ spec: HotkeySpec) throws {
    if spec == binding, hotKeyRef != nil { return }
    try installHandlerIfNeeded()
    nextID += 1
    var newRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: signature, id: nextID)
    let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
    guard status == noErr, let newRef else {
      if hotKeyRef == nil { unregister() }
      throw NSError(domain: "Lowkey", code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: "hotkey \(spec.display) is unavailable (already used by another app?) [\(status)]",
      ])
    }
    if let old = hotKeyRef { UnregisterEventHotKey(old) }
    hotKeyRef = newRef
    binding = spec
  }

  private func installHandlerIfNeeded() throws {
    guard handlerRef == nil else { return }
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    // Unretained: the handler is removed (unregister, deinit) before self goes.
    let userData = Unmanaged.passUnretained(self).toOpaque()
    let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
      guard let event, let userData else { return OSStatus(eventNotHandledErr) }
      let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
      var pressed = EventHotKeyID()
      let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                     nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
      // Another monitor's key: let the next handler have it.
      guard status == noErr, pressed.signature == monitor.signature else { return OSStatus(eventNotHandledErr) }
      // Carbon delivers hot keys on the main thread. HIToolbox swallows an
      // Objective-C exception raised in here without a trace: log it.
      do {
        try ObjCException.catching { monitor.action() }
      } catch {
        Log.write("hotkey: the action raised \(error.localizedDescription)")
      }
      return noErr
    }, 1, &eventType, userData, &handlerRef)
    guard installStatus == noErr else {
      throw NSError(domain: "Lowkey", code: Int(installStatus), userInfo: [NSLocalizedDescriptionKey: "cannot install hotkey handler (\(installStatus))"])
    }
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    binding = nil
    if let handlerRef {
      RemoveEventHandler(handlerRef)
      self.handlerRef = nil
    }
  }
}
