/// An audio input the app can record from, identified by its CoreAudio
/// device UID (stable across launches and reconnections).
public struct AudioInput: Equatable, Hashable, Sendable {
  public let uid: String
  public let name: String

  public init(uid: String, name: String) {
    self.uid = uid
    self.name = name
  }
}

/// The connected inputs and the system default input, as last read.
public struct AudioInputs: Equatable, Sendable {
  public var devices: [AudioInput]
  public var defaultUID: String?

  public init(devices: [AudioInput] = [], defaultUID: String? = nil) {
    self.devices = devices
    self.defaultUID = defaultUID
  }

  public var systemDefault: AudioInput? { devices.first { $0.uid == defaultUID } }
}

/// App-only choice: which input takes record from. Nil follows the system
/// default. A stored device that isn't connected stays chosen, and takes use
/// the system default until it returns.
public struct MicrophoneChoice: Equatable, Sendable {
  /// The stored device: its UID and the name it had when chosen.
  public let stored: AudioInput?
  public let inputs: AudioInputs
  /// A connected device the recorder couldn't use, so takes fell back to
  /// the system default (until the choice or the device list changes).
  public let unusableUID: String?

  public init(stored: AudioInput?, inputs: AudioInputs, unusableUID: String? = nil) {
    self.stored = stored
    self.inputs = inputs
    self.unusableUID = unusableUID
  }

  /// The stored device when connected (with its current name).
  public var connected: AudioInput? { stored.flatMap { stored in inputs.devices.first { $0.uid == stored.uid } } }
  /// The stored device when connected and usable.
  public var chosen: AudioInput? { connected.flatMap { $0.uid == unusableUID ? nil : $0 } }
  public var storedMissing: Bool { stored != nil && connected == nil }
  public var storedUnusable: Bool { connected != nil && chosen == nil }
  /// True when the next take uses whatever the system default input is.
  public var followsSystemDefault: Bool { chosen == nil }
  /// The input the next take records from, if any is known.
  public var effective: AudioInput? { chosen ?? inputs.systemDefault }

  /// The short value shown beside "Microphone" in the menu.
  public var summary: String {
    guard let effective else { return storedMissing || storedUnusable ? "System Default" : "No Input" }
    return storedMissing || storedUnusable ? "\(effective.name) (Default)" : effective.name
  }

  /// Help shown when the stored device is missing.
  public var note: String? {
    guard let stored else { return nil }
    if storedMissing { return "\(stored.name) isn’t connected. Takes use the system default until it is." }
    if storedUnusable { return "Khuluma couldn’t record from \(stored.name). Takes use the system default; choose it again to retry." }
    return nil
  }

  public struct Option: Equatable, Sendable {
    /// Nil for System Default.
    public let uid: String?
    public let title: String
    /// Secondary text: the device System Default resolves to, or "Not connected".
    public let detail: String?
    public let checked: Bool
    public let connected: Bool
  }

  /// System Default first, then connected inputs in system order, then a
  /// stored device that isn't connected.
  public var options: [Option] {
    var options = [Option(uid: nil, title: "System Default", detail: inputs.systemDefault?.name,
                          checked: stored == nil, connected: true)]
    options += inputs.devices.map {
      Option(uid: $0.uid, title: $0.name, detail: nil, checked: $0.uid == stored?.uid, connected: true)
    }
    if let stored, storedMissing {
      options.append(Option(uid: stored.uid, title: stored.name, detail: "Not connected", checked: true, connected: false))
    }
    return options
  }
}
