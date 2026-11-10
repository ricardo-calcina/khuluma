import Foundation
import KhulumaCore

/// Mutable box for values captured inside @Sendable closures (Swift 5 target
/// but keep the pattern explicit, like the CLI's ResultBox).
final class SpansBox: @unchecked Sendable {
  var value: [[Int]]?
}

/// One take's "transcribe while recording" side-band: the disk spool, the
/// segmenter session and the 250 ms timer that feeds both from the recorder.
/// Everything runs on its own serial queue; the audio thread is never
/// touched (samples come from `AudioRecorder.samples(from:)`).
final class LiveTake: @unchecked Sendable {
  let session: LiveSession
  /// The settings (transcription tuple + model path) the session was built
  /// with: process() compares them to the fresh config's before trusting the
  /// prefix.
  let transcription: TranscriptionSettings
  let modelPath: String
  private let writer: LiveSpool.Writer?
  private let queue = DispatchQueue(label: "khuluma.live")
  private let recorder: AudioRecorder
  private var timer: DispatchSourceTimer?
  /// Samples spooled and fed so far — only ever read and written on `queue`.
  private var fed = 0
  private var stopped = false

  init(session: LiveSession, writer: LiveSpool.Writer?,
       transcription: TranscriptionSettings, modelPath: String, recorder: AudioRecorder) {
    self.session = session
    self.writer = writer
    self.transcription = transcription
    self.modelPath = modelPath
    self.recorder = recorder
  }

  /// Start the 250 ms feed timer on the live queue.
  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
      timer.setEventHandler { [weak self] in self?.pull() }
      self.timer = timer
      timer.resume()
    }
  }

  /// New samples since the last pull: spool then feed.
  private func pull() {
    let new = recorder.samples(from: fed)
    guard !new.isEmpty else { return }
    fed += new.count
    writer?.append(new)
    session.feed(new)
  }

  /// Stop the timer, then spool and feed the tail the timer had not yet
  /// pulled: `allSamples[fed...]`, decided here on the live queue after the
  /// timer is dead so nothing is spooled twice. Synchronous; returns after
  /// the spool is fully written.
  func stop(allSamples: [Float]) {
    queue.sync {
      stopped = true
      timer?.cancel()
      timer = nil
      let remaining = Array(allSamples.dropFirst(fed))
      if !remaining.isEmpty {
        fed += remaining.count
        writer?.append(remaining)
        session.feed(remaining)
      }
      writer?.close()
    }
  }

  /// Drop the spool file and cancel the session (cancel/discard routes).
  func discard() {
    queue.sync {
      stopped = true
      timer?.cancel()
      timer = nil
      session.cancel()
      writer?.remove()
    }
  }

  /// Cancel the session but leave the spool: used when the take's audio is
  /// about to be saved elsewhere, and the spool goes only once that save
  /// has succeeded.
  func cancelSession() {
    queue.sync {
      stopped = true
      timer?.cancel()
      timer = nil
      session.cancel()
      writer?.close()
    }
  }

  /// The take settled or its audio went to recovered/: the spool's job is
  /// done. (Session is finished/cancelled by the caller.)
  func removeSpool() {
    writer?.remove()
  }
}
