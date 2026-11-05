import Foundation

/// The last few dictations' first-pass text from `history/*.json`, as the
/// CLI's `history export N` gave it: newest files first (by modification
/// time, then name), the newest `limit` files only, each file's `raw` text.
/// Unreadable, non-object and blank entries are skipped, so there can be
/// fewer than `limit`.
public enum RecentDictations {
  public static func raw(history directory: URL, limit: Int = 10) -> [String] {
    guard limit > 0,
          let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
    var files: [(url: URL, modified: Date)] = []
    for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
      let url = directory.appendingPathComponent(name)
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
            values.isRegularFile == true else { continue }
      files.append((url, values.contentModificationDate ?? .distantPast))
    }
    files.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.url.lastPathComponent > $1.url.lastPathComponent }
    return files.prefix(limit).compactMap { file in
      guard let data = try? Data(contentsOf: file.url),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let raw = object["raw"] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return raw
    }
  }
}
