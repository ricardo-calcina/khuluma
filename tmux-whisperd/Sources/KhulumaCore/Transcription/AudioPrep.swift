import Foundation

/// The CLI's pre-ASR audio steps, sample-exact. Its ffmpeg concat of
/// `anullsrc` appends exactly ms × 16 zero samples, and `-sseof -N` cuts
/// exactly the last N × 16 samples of the padded file (verified against
/// ffmpeg 8.1), so both reduce to array operations on 16 kHz PCM.
public enum AudioPrep {
  public static let sampleRate = 16_000
  /// FluidAudio rejects audio shorter than one second.
  public static let minimumSamples = 16_000

  /// `maybe_pad_transcribe_tail_inplace`, plus the native path's new 1 s
  /// minimum for sub-second takes (which the CLI fails to transcribe).
  public static func padded(_ pcm: [Int16], tailPadMs: Int) -> [Int16] {
    var out = pcm
    if tailPadMs > 0 {
      out.append(contentsOf: repeatElement(0, count: tailPadMs * sampleRate / 1000))
    }
    if out.count < minimumSamples {
      out.append(contentsOf: repeatElement(0, count: minimumSamples - out.count))
    }
    return out
  }

  /// `audio_duration_ms`: ffprobe prints seconds with 6 decimals, awk
  /// multiplies by 1000 and rounds with printf "%.0f".
  public static func ffprobeDurationMs(sampleCount: Int) -> Int {
    let seconds = String(format: "%.6f", Double(sampleCount) / Double(sampleRate))
    let ms = (Double(seconds) ?? 0) * 1000
    return Int(String(format: "%.0f", ms)) ?? 0
  }

  /// The tail-rescue window, in ms, or nil when the CLI would not rescue:
  /// rescue off, audio shorter than the minimum, or not longer than the
  /// window plus one second.
  public static func tailRescueWindowMs(paddedSampleCount: Int, settings: TranscriptionSettings) -> Int? {
    guard settings.tailRescue, var window = settings.rescueMs, let minimum = settings.rescueMinMs else { return nil }
    let duration = ffprobeDurationMs(sampleCount: paddedSampleCount)
    guard duration >= minimum else { return nil }
    window = max(window, 1000)
    guard duration > window + 1000 else { return nil }
    return window
  }

  /// `ffmpeg -sseof -<window>`: the last `windowMs` of audio.
  public static func tail(_ pcm: [Int16], windowMs: Int) -> [Int16] {
    Array(pcm.suffix(windowMs * sampleRate / 1000))
  }
}
