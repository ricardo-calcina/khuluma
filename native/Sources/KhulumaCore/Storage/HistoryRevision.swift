import Darwin
import Foundation

/// "Transcribe again" for a saved history entry: the new raw/processed pair
/// replaces the old one, which moves to `versions` (newest first, at most
/// `maxVersions`, each `{raw, processed, replaced_at}`). Every other key is
/// kept, and the file's modification time is restored so retention still
/// counts from the original take. Readers that don't know `versions` ignore
/// it (they read the JSON as a dictionary).
public enum HistoryRevision {
  public static let maxVersions = 5

  /// `object` with `raw`/`processed` replaced and the previous pair pushed
  /// onto `versions`.
  public static func revised(_ object: [String: Any], raw: String, processed: String,
                             replacedAt: String) -> [String: Any] {
    var out = object
    let previous: [String: Any] = [
      "raw": object["raw"] as? String ?? "",
      "processed": object["processed"] as? String ?? "",
      "replaced_at": replacedAt,
    ]
    let older = (object["versions"] as? [[String: Any]]) ?? []
    out["versions"] = Array(([previous] + older).prefix(maxVersions))
    out["raw"] = raw
    out["processed"] = processed
    return out
  }

  /// Rewrites the entry at `url` atomically, under the data lock (the
  /// history folder's parent's `.data.lock`, as TakeRecorder uses). Throws,
  /// leaving the file untouched, when it is missing or not a JSON object.
  public static func replace(at url: URL, raw: String, processed: String, now: Date = Date(),
                             lockTimeout: TimeInterval = 5) throws {
    let lock = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".data.lock")
    try DataFiles.withLock(lock, timeout: lockTimeout) {
      let data = try Data(contentsOf: url)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw DataFiles.Failure("history entry is not a JSON object: \(url.lastPathComponent)")
      }
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      let revised = revised(object, raw: raw, processed: processed, replacedAt: UsageLedger.isoStamp(now))
      var out = try JSONSerialization.data(withJSONObject: revised,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      out.append(0x0A)
      // Staged under a dot-name (every history reader skips those), given the
      // original mtime and synced before the rename, so a crash leaves the
      // old entry or the new one with its age intact, never a second row.
      let directory = url.deletingLastPathComponent()
      let temp = try DataFiles.writeTemp(out, in: directory, prefix: "." + url.lastPathComponent + ".rev-")
      do {
        if let modified {
          try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temp)
          let fd = open(temp, O_RDONLY | O_CLOEXEC)
          guard fd >= 0 else { throw DataFiles.posix("cannot open", temp) }
          defer { close(fd) }
          guard fsync(fd) == 0 else { throw DataFiles.posix("cannot sync", temp) }
        }
        guard rename(temp, url.path) == 0 else { throw DataFiles.posix("cannot replace", url.path) }
      } catch {
        unlink(temp)
        throw error
      }
      try DataFiles.syncDirectory(directory)
    }
  }
}

/// Retention values in settings.json `history`: `retention_days` 0 (or
/// less) keeps history forever; `audio_retention_days` 0 (or less) keeps no
/// audio. Audio can't outlast history.
public enum HistoryRetention {
  public static func keepsForever(_ retentionDays: Int) -> Bool { retentionDays <= 0 }
  public static func keepsAudio(_ audioRetentionDays: Int) -> Bool { audioRetentionDays > 0 }
  /// The audio days to save given the history days.
  public static func clampedAudio(_ audioDays: Int, history: Int) -> Int {
    keepsForever(history) ? max(audioDays, 0) : min(max(audioDays, 0), history)
  }
}
