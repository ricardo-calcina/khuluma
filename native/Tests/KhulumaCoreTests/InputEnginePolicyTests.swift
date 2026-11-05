import Testing
@testable import KhulumaCore

private let builtIn: UInt32 = 81
private let yeti: UInt32 = 97
private let airPods: UInt32 = 120

/// A pinned engine: its unit reports the device itself.
private func built(_ device: UInt32?, generation: Int = 3, rate: Double = 48_000) -> InputEngineBuild {
  InputEngineBuild(generation: generation, unitDevice: device, target: device, sampleRate: rate, channels: 1)
}

private func seen(_ device: UInt32?, running: Bool = false, alive: Bool = true, wanted: UInt32?,
                  rate: Double = 48_000) -> InputEngineObservation {
  InputEngineObservation(isRunning: running, unitDevice: device, targetAlive: alive, wanted: wanted,
                         sampleRate: rate, channels: 1)
}

/// Following the default, the unit reports AVAudioEngine's aggregate, not the default.
private let aggregate: UInt32 = 112
private func followingDefault(_ target: UInt32, generation: Int = 3) -> InputEngineBuild {
  InputEngineBuild(generation: generation, unitDevice: aggregate, target: target, sampleRate: 44_100, channels: 1)
}

struct InputEnginePolicyTests {
  typealias Policy = InputEnginePolicy

  @Test func aSelfInducedNoticeRightAfterPinningIsIgnored() {
    // Pinning Yeti on a fresh engine posts a change; the engine is where we put it.
    let change = Policy.configurationChanged(notifiedGeneration: 3, built: built(yeti),
                                             observed: seen(yeti, wanted: yeti), recording: false)
    #expect(change == .ignore("same device and format (the engine's own device selection)"))
    // The same notice arriving once the take has started must not end it.
    let during = Policy.configurationChanged(notifiedGeneration: 3, built: built(yeti),
                                             observed: seen(yeti, running: true, wanted: yeti), recording: true)
    #expect(during == .ignore("capture still running on the same device"))
  }

  @Test func aLateNoticeFromAReplacedEngineIsIgnored() {
    for recording in [false, true] {
      let change = Policy.configurationChanged(notifiedGeneration: 2, built: built(yeti, generation: 3),
                                               observed: seen(builtIn, running: false, wanted: yeti), recording: recording)
      #expect(change == .ignore("late notice from a replaced engine"))
    }
  }

  @Test func idleRebuildsOncePerRealChange() {
    // The default moved (AirPods) while following the default.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(builtIn),
                                        observed: seen(builtIn, wanted: airPods), recording: false)
            == .rebuild("a different input is wanted"))
    // The rebuilt engine then reports AirPods: its own notice is ignored, so no loop.
    #expect(Policy.configurationChanged(notifiedGeneration: 4, built: built(airPods, generation: 4),
                                        observed: seen(airPods, wanted: airPods), recording: false)
            == .ignore("same device and format (the engine's own device selection)"))
    // The pinned device unplugged.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(yeti),
                                        observed: seen(yeti, alive: false, wanted: builtIn), recording: false)
            == .rebuild("input device disappeared"))
    // Same device, new sample rate.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(yeti),
                                        observed: seen(yeti, wanted: yeti, rate: 44_100), recording: false)
            == .rebuild("input format changed"))
  }

  @Test func aTakeStopsOnlyWhenCaptureReallyBroke() {
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(builtIn),
                                        observed: seen(builtIn, running: false, wanted: builtIn), recording: true)
            == .stopTake("capture stopped"))
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(builtIn),
                                        observed: seen(airPods, running: true, wanted: airPods), recording: true)
            == .stopTake("input device changed"))
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(yeti),
                                        observed: seen(yeti, running: true, alive: false, wanted: builtIn), recording: true)
            == .stopTake("input device disappeared"))
    // The default moved but the pinned take keeps running: finish it, rebuild after.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: built(builtIn),
                                        observed: seen(builtIn, running: true, wanted: airPods), recording: true)
            == .rebuild("a different input is wanted"))
  }

  @Test func anEngineFollowingTheDefaultIsJudgedByItsTarget() {
    // Unit reports the aggregate; nothing changed: no rebuild, no loop.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: followingDefault(builtIn),
                                        observed: seen(aggregate, wanted: builtIn, rate: 44_100), recording: false)
            == .ignore("same device and format (the engine's own device selection)"))
    #expect(!Policy.rebuildBeforeTake(flagged: false, built: followingDefault(builtIn), wanted: builtIn))
    // The default moved to AirPods.
    #expect(Policy.configurationChanged(notifiedGeneration: 3, built: followingDefault(builtIn),
                                        observed: seen(aggregate, wanted: airPods, rate: 44_100), recording: false)
            == .rebuild("a different input is wanted"))
    #expect(Policy.rebuildBeforeTake(flagged: false, built: followingDefault(builtIn), wanted: airPods))
  }

  @Test func beforeATake() {
    #expect(!Policy.rebuildBeforeTake(flagged: false, built: built(yeti), wanted: yeti))
    #expect(Policy.rebuildBeforeTake(flagged: true, built: built(yeti), wanted: yeti))
    #expect(Policy.rebuildBeforeTake(flagged: false, built: built(builtIn), wanted: yeti))
    #expect(Policy.rebuildBeforeTake(flagged: false, built: built(nil), wanted: builtIn))
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
}
