import Testing
@testable import KhulumaCore

/// The microphone level mapping and the indicator's ring of recent levels.
struct InputLevelTests {
  @Test func silenceIsZero() {
    #expect(InputLevel.normalized(rms: 0) == 0)
  }

  @Test func minus50dBIsTheFloor() {
    #expect(InputLevel.normalized(rms: 0.003162) < 0.001)
  }

  @Test func minus12dBIsFullScale() {
    #expect(InputLevel.normalized(rms: 0.2512) > 0.999)
  }

  @Test func minus31dBIsHalfway() {
    let level = InputLevel.normalized(rms: 0.02818)
    #expect(level > 0.49 && level < 0.51)
  }

  @Test func loudClampsToOne() {
    #expect(InputLevel.normalized(rms: 1) == 1)
  }

  @Test func historyStartsAtZeros() {
    let history = LevelHistory(count: 9)
    #expect(history.levels == [Float](repeating: 0, count: 9))
  }

  @Test func pushesSlideNewestInAtTheEnd() {
    var history = LevelHistory(count: 4)
    for level in [Float]([0.1, 0.2, 0.3, 0.4]) { history.push(level) }
    #expect(history.levels == [0.1, 0.2, 0.3, 0.4])
    history.push(0.5)
    #expect(history.levels == [0.2, 0.3, 0.4, 0.5])
    #expect(history.levels.count == 4)
  }
}
