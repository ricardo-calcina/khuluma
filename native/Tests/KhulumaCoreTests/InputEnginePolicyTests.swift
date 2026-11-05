import Testing
@testable import KhulumaCore

private let builtIn: UInt32 = 81
private let yeti: UInt32 = 97
private let airPods: UInt32 = 120

/// A pinned engine: its unit reports the device itself.
private func pinned(_ device: UInt32, generation: Int = 3, rate: Double = 48_000) -> InputEngineBuild {
  InputEngineBuild(generation: generation, unitDevice: device, target: .pinned(device), sampleRate: rate, channels: 1)
}

/// Following the default, the unit reports AVAudioEngine's aggregate, not the default.
private let aggregate: UInt32 = 112
private func following(_ device: UInt32?, generation: Int = 3, defaultAtStart: UInt32? = nil) -> InputEngineBuild {
  InputEngineBuild(generation: generation, unitDevice: aggregate, target: .followingDefault(device),
                   sampleRate: 44_100, channels: 1, defaultAtStart: defaultAtStart)
}

private func seen(_ unit: UInt32?, running: Bool = false, alive: Bool = true, wanted: InputTarget,
                  systemDefault: UInt32? = builtIn, rate: Double = 48_000) -> InputEngineObservation {
  InputEngineObservation(isRunning: running, unitDevice: unit, targetAlive: alive, wanted: wanted,
                         systemDefault: systemDefault, sampleRate: rate, channels: 1)
}

struct InputEnginePolicyTests {
  typealias Policy = InputEnginePolicy

  @Test func aSelfInducedNoticeRightAfterPinningIsIgnored() {
    // Pinning Yeti on a fresh engine posts a change; the engine is where we put it.
    let change = Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                             observed: seen(yeti, wanted: .pinned(yeti)), recording: false)
    #expect(change == .ignore("same device and format (the engine's own device selection)"))
    // The same notice arriving once the take has started must not end it.
    let during = Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                             observed: seen(yeti, running: true, wanted: .pinned(yeti)), recording: true)
    #expect(during == .ignore("capture still running on the same device"))
  }

  @Test func aLateNoticeFromAReplacedEngineIsIgnored() {
    for recording in [false, true] {
      for build in [pinned(yeti, generation: 3), following(builtIn, generation: 3, defaultAtStart: builtIn)] {
        let change = Policy.configurationChanged(notifiedGeneration: 2, built: build,
                                                 observed: seen(builtIn, running: false, wanted: .pinned(yeti),
                                                                systemDefault: airPods),
                                                 recording: recording)
        #expect(change == .ignore("late notice from a replaced engine"))
      }
    }
  }

  @Test func idleRebuildsOncePerRealChange() {
    // The default moved (AirPods) while following the default.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: following(builtIn),
                                        observed: seen(aggregate, wanted: .followingDefault(airPods), rate: 44_100),
                                        recording: false)
            == .rebuild("a different input is wanted"))
    // The rebuilt engine follows AirPods: its own notice is ignored, so no loop.
    #expect(Policy.configurationChanged(notifiedGeneration: 4, built: following(airPods, generation: 4),
                                        observed: seen(aggregate, wanted: .followingDefault(airPods), rate: 44_100),
                                        recording: false)
            == .ignore("same device and format (the engine's own device selection)"))
    // The pinned device unplugged.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                        observed: seen(yeti, alive: false, wanted: .followingDefault(builtIn)),
                                        recording: false)
            == .rebuild("input device disappeared"))
    // Same device, new sample rate.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                        observed: seen(yeti, wanted: .pinned(yeti), rate: 44_100), recording: false)
            == .rebuild("input format changed"))
  }

  @Test func aPinnedTakeStopsOnlyWhenCaptureReallyBroke() {
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                        observed: seen(yeti, running: false, wanted: .pinned(yeti)), recording: true)
            == .stopTake("capture stopped"))
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                        observed: seen(airPods, running: true, wanted: .pinned(yeti)), recording: true)
            == .stopTake("input device changed"))
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                        observed: seen(yeti, running: true, alive: false, wanted: .followingDefault(builtIn)),
                                        recording: true)
            == .stopTake("input device disappeared"))
    // The default moved but the pinned take keeps running: finish it, nothing to redo.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: pinned(yeti),
                                        observed: seen(yeti, running: true, wanted: .pinned(yeti), systemDefault: airPods),
                                        recording: true)
            == .ignore("capture still running on the same device"))
  }

  @Test func aDefaultTakeStopsWhenTheDefaultMovesLikeBefore() {
    // The aggregate keeps its ID and format when its input moves: compare the default itself.
    let take = following(builtIn, defaultAtStart: builtIn)
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: take,
                                        observed: seen(aggregate, running: true, wanted: .followingDefault(airPods),
                                                       systemDefault: airPods, rate: 44_100),
                                        recording: true)
            == .stopTake("system default input changed"))
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: take,
                                        observed: seen(aggregate, running: false, wanted: .followingDefault(builtIn),
                                                       systemDefault: builtIn, rate: 44_100),
                                        recording: true)
            == .stopTake("capture stopped"))
    // Same default, still running (e.g. another device was plugged in): keep recording.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: take,
                                        observed: seen(aggregate, running: true, wanted: .followingDefault(builtIn),
                                                       systemDefault: builtIn, rate: 44_100),
                                        recording: true)
            == .ignore("capture still running on the same default input"))
  }

  @Test func choosingTheCurrentDefaultExplicitlyPinsIt() {
    // Following the default on the built-in mic, then choosing that same mic:
    // the device matches but the mode doesn't, so the engine is rebuilt pinned.
    #expect(Policy.rebuildBeforeTake(flagged: false, built: following(builtIn), wanted: .pinned(builtIn)))
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: following(builtIn),
                                        observed: seen(aggregate, wanted: .pinned(builtIn), rate: 44_100), recording: false)
            == .rebuild("a different input is wanted"))
    // And back to System Default while the default is still that mic.
    #expect(Policy.rebuildBeforeTake(flagged: false, built: pinned(builtIn), wanted: .followingDefault(builtIn)))
    // Retrying a failed choice that equals the default (fallback followed the default).
    #expect(Policy.rebuildBeforeTake(flagged: false, built: following(builtIn), wanted: .pinned(builtIn)))
  }

  @Test func beforeATake() {
    #expect(!Policy.rebuildBeforeTake(flagged: false, built: pinned(yeti), wanted: .pinned(yeti)))
    #expect(!Policy.rebuildBeforeTake(flagged: false, built: following(builtIn), wanted: .followingDefault(builtIn)))
    #expect(Policy.rebuildBeforeTake(flagged: true, built: pinned(yeti), wanted: .pinned(yeti)))
    #expect(Policy.rebuildBeforeTake(flagged: false, built: pinned(builtIn), wanted: .pinned(yeti)))
    #expect(Policy.rebuildBeforeTake(flagged: false, built: following(nil), wanted: .followingDefault(builtIn)))
    #expect(Policy.rebuildBeforeTake(flagged: false, built: following(builtIn), wanted: .followingDefault(airPods)))
  }

  @Test func selectionIsCheckedAgainstTheReadBack() {
    #expect(Policy.selection(requested: nil, setStatus: nil, actual: builtIn) == .followDefault)
    #expect(Policy.selection(requested: yeti, setStatus: 0, actual: yeti) == .accepted)
    #expect(Policy.selection(requested: yeti, setStatus: -10851, actual: builtIn)
            == .fallBack("setting the device failed (OSStatus -10851)"))
    #expect(Policy.selection(requested: yeti, setStatus: 0, actual: builtIn)
            == .fallBack("the engine reports device 81, not 97"))
    #expect(Policy.selection(requested: yeti, setStatus: 0, actual: nil) == .fallBack("the engine reports no device"))
    #expect(Policy.selection(requested: yeti, setStatus: nil, actual: nil) == .fallBack("the device was not set"))
  }

  @Test func aDeviceIsAliveOnlyWhenCoreAudioSaysSo() {
    #expect(CoreAudioReading.isAlive(1))
    #expect(!CoreAudioReading.isAlive(0))
    // A removed device often can't be queried at all: that is not alive.
    #expect(!CoreAudioReading.isAlive(nil))
    #expect(!CoreAudioReading.isAlive(2))
  }
}

struct CaptureStartPolicyTests {
  typealias Policy = CaptureStartPolicy
  private let prepared = CaptureFormat(sampleRate: 48_000, channels: 1)
  private let settled = CaptureFormat(sampleRate: 24_000, channels: 1)

  @Test func theTapFollowsTheHardwareFormatReadAtStart() {
    // Continuity: prepared at 48 kHz, the iPhone mic reports 24 kHz once active.
    #expect(Policy.tapFormat(hardware: settled, node: prepared) == settled)
    #expect(Policy.tapFormat(hardware: prepared, node: prepared) == prepared)
  }

  @Test func theNodeFormatIsOnlyAFallbackAndNothingUsableThrows() {
    #expect(Policy.tapFormat(hardware: CaptureFormat(sampleRate: 0, channels: 0), node: prepared) == prepared)
    #expect(Policy.tapFormat(hardware: nil, node: prepared) == prepared)
    #expect(Policy.tapFormat(hardware: nil, node: CaptureFormat(sampleRate: 48_000, channels: 0)) == nil)
  }

  @Test func theConverterIsRebuiltWhenBuffersArriveInAnotherFormat() {
    #expect(!Policy.needsNewConverter(builtFor: prepared, buffer: prepared))
    #expect(Policy.needsNewConverter(builtFor: prepared, buffer: settled))
    #expect(Policy.needsNewConverter(builtFor: nil, buffer: prepared))
  }

  @Test func aChosenMicGetsOneMoreTryThenTheDefaultKeepsTheTake() {
    #expect(Policy.recovery(afterFailure: 1, pinned: true) == .sameDevice)
    #expect(Policy.recovery(afterFailure: 2, pinned: true) == .systemDefault)
    // Now on the default: its failure ends it (three attempts in all).
    #expect(Policy.recovery(afterFailure: 3, pinned: false) == nil)
  }

  @Test func theDefaultGetsOneFreshRetryAsBefore() {
    #expect(Policy.recovery(afterFailure: 1, pinned: false) == .freshEngine)
    #expect(Policy.recovery(afterFailure: 2, pinned: false) == nil)
  }

  @Test func aSameDeviceRetryThatFellBackWhileBuildingDoesNotRetryAgain() {
    // The rebuild for the same device couldn't pin and built on the default.
    #expect(Policy.recovery(afterFailure: 2, pinned: false) == nil)
  }
}
