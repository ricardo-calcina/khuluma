import Testing
@testable import LowkeyCore

/// The menu-bar status through a take's life, as the controller drives it.
struct ActivityStatusTests {
  @Test func aTakeGoesRecordingProcessingReady() {
    var status = ActivityStatus()
    #expect(status.phase == .ready && status.title == "Ready" && status.symbol == "mic")
    status.recordingStarted()
    #expect(status.phase == .recording && status.title == "Recording…" && status.symbol == "mic.fill")
    status.processingStarted()
    #expect(status.phase == .processing && status.processing == 1 && status.title == "Processing…")
    status.processingFinished(error: nil, recording: false)
    #expect(status.phase == .ready && status.processing == 0)
  }

  @Test func aRecordingStartedWhileProcessingStaysShownUntilItEnds() {
    var status = ActivityStatus()
    status.recordingStarted()
    status.processingStarted()
    status.recordingStarted()
    // The first take finishes while the second is still recording.
    status.processingFinished(error: nil, recording: true)
    #expect(status.phase == .recording && status.processing == 0)
  }

  @Test func overlappingTakesAreCounted() {
    var status = ActivityStatus()
    status.processingStarted()
    status.processingStarted()
    #expect(status.title == "Processing (2)…")
    status.processingFinished(error: nil, recording: false)
    #expect(status.phase == .processing && status.title == "Processing…")
    status.processingFinished(error: nil, recording: false)
    #expect(status.phase == .ready)
  }

  @Test func cancelReturnsToWhateverElseIsGoingOn() {
    var idle = ActivityStatus()
    idle.recordingStarted()
    idle.recordingCancelled()
    #expect(idle.phase == .ready)

    var busy = ActivityStatus()
    busy.processingStarted()
    busy.recordingStarted()
    busy.recordingCancelled()
    #expect(busy.phase == .processing && busy.processing == 1)
  }

  @Test func anErrorStaysUntilReplacedOrCleared() {
    var status = ActivityStatus()
    status.processingStarted()
    status.processingFinished(error: "transcription timed out after 30s", recording: false)
    #expect(status.phase == .error("transcription timed out after 30s"))
    #expect(status.title == "Error: transcription timed out after 30s" && status.symbol == "exclamationmark.triangle")
    #expect(status.processing == 0)
    status.recordingStarted()
    #expect(status.phase == .recording)
    status.failed("no audio captured (microphone permission?)")
    let cleared = status.clearError()
    #expect(cleared && status.phase == .ready)
    let clearedAgain = status.clearError()
    #expect(!clearedAgain)
  }

  @Test func clearingAnErrorKeepsTakesInProgressVisible() {
    var status = ActivityStatus()
    status.processingStarted()
    status.failed("cannot read settings: timed out")
    status.clearError()
    #expect(status.phase == .processing)
  }

  @Test func finishingNeverCountsBelowZero() {
    var status = ActivityStatus()
    status.processingFinished(error: nil, recording: false)
    #expect(status.processing == 0 && status.phase == .ready)
  }
}
