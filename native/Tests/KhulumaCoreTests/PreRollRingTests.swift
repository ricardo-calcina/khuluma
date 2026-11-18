import KhulumaCore
import Testing

struct PreRollRingTests {
  @Test func emptyDrainIsEmpty() {
    var ring = PreRollRing(capacity: 4)
    #expect(ring.drain().isEmpty)
    #expect(ring.count == 0)
  }

  @Test func keepsWhatFits() {
    var ring = PreRollRing(capacity: 4)
    ring.append([1, 2, 3])
    #expect(ring.count == 3)
    #expect(ring.drain() == [1, 2, 3])
  }

  @Test func capacityBoundKeepsNewest() {
    var ring = PreRollRing(capacity: 4)
    ring.append([1, 2, 3, 4, 5, 6, 7])
    #expect(ring.count == 4)
    #expect(ring.drain() == [4, 5, 6, 7])
  }

  @Test func wrapsAroundAcrossAppends() {
    var ring = PreRollRing(capacity: 4)
    ring.append([1, 2, 3])
    ring.append([4, 5])
    ring.append([6])
    #expect(ring.drain() == [3, 4, 5, 6])
  }

  @Test func drainClears() {
    var ring = PreRollRing(capacity: 4)
    ring.append([1, 2, 3, 4, 5])
    _ = ring.drain()
    #expect(ring.count == 0)
    #expect(ring.drain().isEmpty)
    ring.append([9])
    #expect(ring.drain() == [9])
  }

  @Test func clearEmpties() {
    var ring = PreRollRing(capacity: 4)
    ring.append([1, 2])
    ring.clear()
    #expect(ring.drain().isEmpty)
  }

  @Test func defaultIsHalfASecondAt16k() {
    #expect(PreRollRing().capacity == 8_000)
  }
}
