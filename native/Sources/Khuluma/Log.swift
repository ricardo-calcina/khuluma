import Foundation
import KhulumaCore

/// Append-only log at ~/Library/Logs/Khuluma/app.log (timings, errors).
enum Log {
  static let directory = AppRuntimePaths.logs
  static let fileURL = directory.appendingPathComponent("app.log")
  private static let queue = DispatchQueue(label: "khuluma.log")
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static func write(_ message: String) {
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    queue.async {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let handle = try? FileHandle(forWritingTo: fileURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
      } else {
        try? Data(line.utf8).write(to: fileURL)
      }
    }
  }
}

/// Monotonic milliseconds for latency measurements.
func monotonicMs() -> Double {
  Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}
