import AppKit
import Foundation
import KhulumaCore
import UserNotifications

/// Finder's Local and Cloud services share output handling. Local jobs yield
/// to dictation; cloud jobs upload the selected files after confirmation.
final class QuickActionService: NSObject {
  private enum Destination: String {
    case local, cloud
  }

  /// Read on the main thread: the app is still starting, or a take is
  /// recording or in flight.
  var dictationBusy: () -> Bool = { false }
  var localDaemon: () -> DaemonProcess? = { nil }
  var prepareLocalModel: () -> Void = {}
  /// The current settings (any queue).
  var loadConfig: () -> AppConfig?
  private let queue = DispatchQueue(label: "khuluma.quick-action", qos: .utility)
  private let scribe = ScribeClient()

  init(loadConfig: @escaping () -> AppConfig?) {
    self.loadConfig = loadConfig
  }

  /// The NSServices message: `transcribeFiles:userData:error:`.
  @objc func transcribeFiles(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    // Older Launch Services registrations had no user data and were local.
    guard let destination = Destination(rawValue: userData ?? "local") else { return }
    let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    guard !urls.isEmpty else {
      Self.notify("No files selected.")
      return
    }
    Log.write("quick action: \(urls.count) file(s)")
    DispatchQueue.main.async { [weak self] in
      guard let self, destination == .local || Self.confirmUpload(urls) else { return }
      self.queue.async { [weak self] in self?.run(urls, destination: destination) }
    }
  }

  private static func confirmUpload(_ urls: [URL]) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Transcribe with Cloud?"
    let selection = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) selected files"
    alert.informativeText = "Khuluma will upload \(selection) to ElevenLabs for transcription. This uses your API credits."
    let upload = alert.addButton(withTitle: "Upload and Transcribe")
    upload.keyEquivalent = ""
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    NSApp.activate()
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func run(_ urls: [URL], destination: Destination) {
    let selection = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    Self.notify("Transcribing \(selection) \(destination == .local ? "locally" : "with ElevenLabs")…")
    let outcome: QuickActionRun.Outcome
    switch destination {
    case .local:
      waitForDictation()
      outcome = QuickActionRun.run(
        urls.map(\.path), engine: { try self.engine() },
        waitWhileBusy: { self.waitForDictation() },
        workDirectory: { try FileTranscribeCommand.privateWorkDirectory() })
    case .cloud:
      outcome = QuickActionRun.run(urls.map(\.path), workDirectory: { try FileTranscribeCommand.privateWorkDirectory() }) {
        try scribe.transcribeFile($0, workDirectory: $1)
      }
    }
    for failure in outcome.failures { Log.write("quick action: \(failure)") }
    if !outcome.combined.isEmpty {
      DispatchQueue.main.sync {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outcome.combined, forType: .string)
      }
    }
    Self.notify(outcome.notification)
  }

  private func engine() throws -> FileTranscriber.Engine {
    guard let config = loadConfig() else { throw FileTranscriber.Failure("Khuluma is still starting") }
    let t = config.transcription
    guard let model = t.modelPath, !model.isEmpty else {
      DispatchQueue.main.sync { prepareLocalModel() }
      throw FileTranscriber.Failure("The local model isn't ready. Try again after it downloads.")
    }
    let version = t.modelVersion ?? "v3"
    guard !t.socketPath.isEmpty, let daemon = DispatchQueue.main.sync(execute: localDaemon) else {
      throw FileTranscriber.Failure("Khuluma's speech engine is unavailable")
    }
    switch daemon.ensureRunning() {
    case .running, .external: break
    case .restarting: throw FileTranscriber.Failure("The local speech engine is restarting. Try again shortly.")
    case .unavailable(let reason): throw FileTranscriber.Failure(reason)
    }
    let status = DaemonClient(socketPath: t.socketPath).status(timeout: 0.25)
    if status?.holds(path: model, version: version) != true {
      waitForDictation()
      let target = DaemonSupervisor.Target(socketPath: t.socketPath, modelPath: model, modelVersion: version)
      let report = try DaemonSupervisor.ownedWarmup(process: daemon)(target)
      guard report.state == .ready else {
        throw FileTranscriber.Failure(report.message ?? "The local speech engine is still starting. Try again shortly.")
      }
    }
    return .daemon(socketPath: t.socketPath, modelPath: model, modelVersion: version, language: t.language)
  }

  /// A dictation take goes first: wait between files while one is active.
  private func waitForDictation() {
    while DispatchQueue.main.sync(execute: { dictationBusy() }) {
      Thread.sleep(forTimeInterval: 0.5)
    }
  }

  /// Fire-and-forget; the first one may wait on the permission prompt.
  static func notify(_ message: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { granted, _ in
      guard granted else {
        Log.write("quick action: notifications not allowed (\(message))")
        return
      }
      let content = UNMutableNotificationContent()
      content.title = "Khuluma"
      content.body = message
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }
}
