/// The last few hundred ms of idle 16 kHz audio, for "Keep microphone ready"
/// (Settings › Labs). Fixed capacity: older samples are overwritten. At take
/// start `drain()` hands back the contents oldest first and empties the ring.
public struct PreRollRing: Sendable {
  /// 500 ms at 16 kHz.
  public static let defaultCapacity = 8_000

  public let capacity: Int
  private var storage: [Float]
  /// Next write position.
  private var head = 0
  public private(set) var count = 0

  public init(capacity: Int = PreRollRing.defaultCapacity) {
    precondition(capacity > 0)
    self.capacity = capacity
    storage = [Float](repeating: 0, count: capacity)
  }

  public mutating func append<S: Collection>(_ samples: S) where S.Element == Float {
    // Only the newest `capacity` samples can survive.
    var slice = samples[...]
    if slice.count > capacity { slice = slice.suffix(capacity) }
    for sample in slice {
      storage[head] = sample
      head = (head + 1) % capacity
    }
    count = min(capacity, count + slice.count)
  }

  /// The contents, oldest first; the ring is empty afterwards.
  public mutating func drain() -> [Float] {
    guard count > 0 else { return [] }
    let start = (head - count + capacity) % capacity
    let out: [Float] = start + count <= capacity
      ? Array(storage[start..<(start + count)])
      : Array(storage[start...]) + Array(storage[..<((start + count) % capacity)])
    clear()
    return out
  }

  public mutating func clear() {
    head = 0
    count = 0
  }
}
