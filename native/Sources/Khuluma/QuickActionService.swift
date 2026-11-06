import AppKit
import Foundation
import KhulumaCore
import UserNotifications

/// Finder's "Transcribe with Khuluma" Quick Action (NSServices entry
/// `transcribeFiles` in Info.plist): each selected file is transcribed by
/// the app's own daemon, written as `<name>.txt` beside it (never over an
/// existing file, never partial), and the transcripts go to the clipboard.
/// One file at a time, off the main thread, waiting while a dictation take is
/// recording or being transcribed. Not counted in usage or history.
final class QuickActionService: NSObject {
  /// Read on the main thread: the app is still starting, or a take is
  /// recording or in flight.
  var dictationBusy: () -> Bool = { false }
  /// The current settings (any queue).
  var loadConfig: () -> AppConfig?
  private let queue = DispatchQueue(label: "khuluma.quick-action", qos: .utility)

  init(loadConfig: @escaping () -> AppConfig?) {
    self.loadConfig = loadConfig
  }

  /// The NSServices message: `transcribeFiles:userData:error:`.
  @objc func transcribeFiles(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    guard !urls.isEmpty else {
      Self.notify("No files selected.")
      return
    }
    Log.write("quick action: \(urls.count) file(s)")
    queue.async { [weak self] in self?.run(urls) }
  }

  private func run(_ urls: [URL]) {
    Self.notify(urls.count == 1 ? "Transcribing \(urls[0].lastPathComponent)..." : "Transcribing \(urls.count) files...")
    let outcome = QuickActionRun.run(
      urls.map(\.path),
      engine: { [weak self] in
        guard let self else { throw FileTranscriber.Failure("Khuluma is quitting") }
        return try self.engine()
      },
      waitWhileBusy: { [weak self] in self?.waitForDictation() },
      workDirectory: { try FileTranscribeCommand.privateWorkDirectory() })
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
    guard let model = t.modelPath, !model.isEmpty else { throw FileTranscriber.Failure(FileEngineChoice.noModelMessage) }
    guard !t.socketPath.isEmpty else { throw FileTranscriber.Failure("Khuluma's speech engine is unavailable") }
    return .daemon(socketPath: t.socketPath, modelPath: model, modelVersion: t.modelVersion ?? "v3", language: t.language)
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
