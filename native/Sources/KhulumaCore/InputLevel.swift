import Foundation

/// Microphone level for the on-screen indicator: RMS → a 0…1 bar height.
public enum InputLevel {
  /// −50 dB reads as silence (0), −12 dB as full scale (1), linear in dB
  /// and clamped, so the bars move where speech actually sits.
  public static func normalized(rms: Float) -> Float {
    let db = 20 * log10(max(rms, 1e-7))
    return min(max((db + 50) / 38, 0), 1)
  }
}

/// The last N levels, oldest first, for the indicator's bars.
public struct LevelHistory {
  public private(set) var levels: [Float]

  public init(count: Int) {
    levels = [Float](repeating: 0, count: count)
  }

  public mutating func push(_ level: Float) {
    levels.removeFirst()
    levels.append(level)
  }
}
