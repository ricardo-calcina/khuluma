import Carbon.HIToolbox
import Foundation
import LowkeyCore

/// A system-wide hotkey via Carbon `RegisterEventHotKey`, which needs no
/// Accessibility or Input Monitoring permission.
final class HotkeyMonitor {
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private let action: () -> Void
  private static weak var current: HotkeyMonitor?

  init(action: @escaping () -> Void) {
    self.action = action
  }

  deinit {
    unregister()
  }

  func register(_ spec: HotkeySpec) throws {
    unregister()
    HotkeyMonitor.current = self

    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      // Carbon delivers hot keys on the main thread. HIToolbox swallows an
      // Objective-C exception raised in here without a trace: log it.
      do {
        try ObjCException.catching { HotkeyMonitor.current?.action() }
      } catch {
        Log.write("hotkey: the action raised \(error.localizedDescription)")
      }
      return noErr
    }, 1, &eventType, nil, &handlerRef)
    guard installStatus == noErr else {
      throw NSError(domain: "Lowkey", code: Int(installStatus), userInfo: [NSLocalizedDescriptionKey: "cannot install hotkey handler (\(installStatus))"])
    }

    let hotKeyID = EventHotKeyID(signature: OSType(0x4C4F574B), id: 1) // 'LOWK'
    let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    guard status == noErr else {
      unregister()
      throw NSError(domain: "Lowkey", code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: "hotkey \(spec.display) is unavailable (already used by another app?) [\(status)]",
      ])
    }
  }

  func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let handlerRef {
      RemoveEventHandler(handlerRef)
      self.handlerRef = nil
    }
    if HotkeyMonitor.current === self {
      HotkeyMonitor.current = nil
    }
  }
}
