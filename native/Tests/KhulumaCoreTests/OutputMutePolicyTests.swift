import Testing
@testable import KhulumaCore

/// The mute-while-recording decisions behind `OutputMuter`.
struct OutputMutePolicyTests {
  @Test func anAlreadyMutedDeviceIsLeftAlone() {
    let plan = OutputMutePolicy.plan(muteSettable: true, currentlyMuted: true,
                                     volumeSettable: true, currentVolume: 0.5)
    guard case .none = plan else { Issue.record("planned a change on a muted device"); return }
  }

  @Test func aSettableMuteIsUsed() {
    #expect(OutputMutePolicy.plan(muteSettable: true, currentlyMuted: false,
                                  volumeSettable: true, currentVolume: 0.5) == .setMute)
  }

  @Test func onlyVolumeSettableZeroesItAndRemembers() {
    #expect(OutputMutePolicy.plan(muteSettable: false, currentlyMuted: false,
                                  volumeSettable: true, currentVolume: 0.42) == .zeroVolume(restore: 0.42))
  }

  @Test func nothingSettableDoesNothing() {
    guard case .none = OutputMutePolicy.plan(muteSettable: false, currentlyMuted: false,
                                             volumeSettable: false, currentVolume: 0.4) else {
      Issue.record("planned a change with nothing settable"); return
    }
    // No way back from zeroed volume: an already-silent device is left alone.
    guard case .none = OutputMutePolicy.plan(muteSettable: false, currentlyMuted: false,
                                             volumeSettable: true, currentVolume: 0) else {
      Issue.record("planned to zero an already-zero volume"); return
    }
  }

  @Test func restoreWhileTheDeviceIsStillAsLeft() {
    #expect(OutputMutePolicy.shouldRestore(applied: .setMute, nowMuted: true, nowVolume: 0.5))
    #expect(OutputMutePolicy.shouldRestore(applied: .zeroVolume(restore: 0.4), nowMuted: false, nowVolume: 0))
  }

  @Test func aUserChangeIsNotUndone() {
    // They unmuted, or raised the volume: leave it.
    #expect(!OutputMutePolicy.shouldRestore(applied: .setMute, nowMuted: false, nowVolume: 0.5))
    #expect(!OutputMutePolicy.shouldRestore(applied: .zeroVolume(restore: 0.4), nowMuted: false, nowVolume: 0.3))
    // Nothing applied: nothing to restore.
    #expect(!OutputMutePolicy.shouldRestore(applied: .none(reason: "x"), nowMuted: true, nowVolume: 0))
  }
}
