import AVFoundation
import Foundation
import KhulumaCore

/// Preloaded sound effects, so the start chime plays in milliseconds instead
/// of the ~0.3-0.9 s an `afplay` process needs.
final class SoundPlayer {
  enum Event: String, CaseIterable {
    case start, stop, process, error, cancel
  }

  /// Loaded on main, read from any thread (the start chime plays from the
  /// audio thread).
  private var players: [Event: AVAudioPlayer] = [:]
  private let lock = NSLock()

  func load(from config: AppConfig) {
    var players: [Event: AVAudioPlayer] = [:]
    for event in Event.allCases {
      guard let sound = config.sounds[event.rawValue], sound.enabled, let path = sound.path else { continue }
      do {
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        player.prepareToPlay()
        players[event] = player
      } catch {
        Log.write("sound: cannot load \(event.rawValue) from \(path): \(error.localizedDescription)")
      }
    }
    lock.withLock { self.players = players }
  }

  /// The loaded sound's duration, or nil when the event has no sound (the
  /// mute-after-chime timing falls back to muting at take start).
  func duration(_ event: Event) -> TimeInterval? {
    lock.withLock { players[event]?.duration }
  }

  private let queue = DispatchQueue(label: "khuluma.sound", qos: .userInteractive)

  /// Plays without blocking the caller: on a cold output device `play()` can
  /// take 100+ ms, which must not delay starting the microphone.
  func play(_ event: Event, onStarted: ((Double) -> Void)? = nil) {
    guard let player = lock.withLock({ players[event] }) else { return }
    queue.async {
      let started = monotonicMs()
      player.stop()
      player.currentTime = 0
      player.play()
      onStarted?(monotonicMs() - started)
    }
  }
}

/// One short-lived player per tap on a Settings play button: independent of
/// the preloaded SoundPlayer and of the master switch.
final class SoundPreview {
  private var player: AVAudioPlayer?

  /// Plays the file once; a missing or unreadable file is silent.
  func play(_ path: String) {
    do {
      let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
      self.player = player
      player.play()
    } catch {
      player = nil
    }
  }
}
