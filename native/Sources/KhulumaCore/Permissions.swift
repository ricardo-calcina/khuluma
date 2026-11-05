import Foundation

/// What the app needs macOS to allow, and what it says when it doesn't.
/// Pure decisions and wording; the system calls live in the app target
/// (`Permissions.swift`) so these are testable.
public enum PermissionPolicy {
  public enum Pane: Equatable, Sendable {
    case microphone, keyboard

    /// System Settings → Privacy & Security. Posting key events is granted
    /// under Accessibility.
    public var url: String {
      switch self {
      case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
      case .keyboard: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      }
    }
  }

  /// A notice for the menu: what's wrong and which pane fixes it.
  public struct Notice: Equatable, Sendable {
    public let title: String
    public let pane: Pane
  }

  public static let microphoneNotice = Notice(
    title: "Microphone access is off: allow Khuluma in Settings", pane: .microphone)
  public static let keyboardNotice = Notice(
    title: "Allow Khuluma to control the keyboard so it can paste (Settings)", pane: .keyboard)

  /// Domain and codes of the errors the app's deliverer throws (the take log
  /// maps them to short categories).
  public static let errorDomain = "Khuluma"
  public static let accessibilityMissingCode = 2
  public static let postEventMissingCode = 5

  /// Why a delivery can't type into other apps, or nil when it can. Checked
  /// after the text is on the clipboard; a denied or revoked permission fails
  /// the delivery (nothing is typed, nothing is counted).
  public static func deliveryFailure(accessibilityTrusted: Bool, postEventAllowed: Bool) -> NSError? {
    if !accessibilityTrusted {
      return NSError(domain: errorDomain, code: accessibilityMissingCode, userInfo: [
        NSLocalizedDescriptionKey: "Accessibility permission missing: text is on the clipboard (System Settings → Privacy & Security → Accessibility → Khuluma)",
      ])
    }
    if !postEventAllowed {
      return NSError(domain: errorDomain, code: postEventMissingCode, userInfo: [
        NSLocalizedDescriptionKey: "Couldn't paste: allow Khuluma to control the keyboard (Settings)",
      ])
    }
    return nil
  }

  /// True for the message a refused keyboard (post-event) permission produces.
  public static func isKeyboardFailure(_ message: String) -> Bool {
    message == deliveryFailure(accessibilityTrusted: true, postEventAllowed: false)?.localizedDescription
  }

  /// The menu notice for a failed delivery's message: a revoked Accessibility
  /// permission or a refused post-event one both open the keyboard pane.
  public static func notice(forFailure message: String) -> Notice? {
    let accessibility = deliveryFailure(accessibilityTrusted: false, postEventAllowed: true)?.localizedDescription
    return isKeyboardFailure(message) || message == accessibility ? keyboardNotice : nil
  }

  public enum MicrophoneStatus: Equatable, Sendable { case authorized, notDetermined, denied }

  /// A take may start unless the microphone is denied. (A denied microphone
  /// still delivers buffers, of silence, so the take must not begin.)
  public static func microphoneNotice(for status: MicrophoneStatus) -> Notice? {
    status == .denied ? microphoneNotice : nil
  }
}
