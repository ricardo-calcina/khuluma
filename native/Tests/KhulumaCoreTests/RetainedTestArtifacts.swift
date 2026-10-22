import Foundation

/// Generated fixture roots are retained in the temporary directory for recovery.
/// When a test needs a path cleared to exercise recovery, move its fixture aside.
enum RetainedTestArtifacts {
  static func moveAside(_ url: URL) throws {
    let destination = url.deletingLastPathComponent()
      .appendingPathComponent("retained-\(UUID().uuidString)-\(url.lastPathComponent)")
    try FileManager.default.moveItem(at: url, to: destination)
  }
}
