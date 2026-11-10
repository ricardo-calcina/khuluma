import Foundation

/// Cuts a live recording at pauses so finished segments can transcribe while
/// the take still runs. Fed 16 kHz mono Float samples in any chunk size; cuts
/// are absolute sample indexes into everything fed so far. Pure value type.
public struct PauseSegmenter: Sendable {
  public struct Config: Equatable, Sendable {
    public var minSegmentMs = 12_000     // no cut before the open segment is this long
    public var maxSegmentMs = 30_000     // forced cut when no pause was found
    public var pauseMs = 360             // run of silent frames that counts as a pause
    public var frameMs = 20
    public var floorWindowFrames = 250   // 5 s of frames for the noise floor
    public var marginDb: Float = 8
    public var minThresholdDb: Float = -55
    public var maxThresholdDb: Float = -38
    public var forcedSearchMs = 5_000    // a forced cut looks this far back for the quietest spot
    public init() {}
  }

  public struct Cut: Equatable, Sendable {
    public let sample: Int
    public let forced: Bool
    public init(sample: Int, forced: Bool) {
      self.sample = sample
      self.forced = forced
    }
  }

  public let config: Config
  /// Start of the open (not yet cut) segment, absolute sample index.
  public private(set) var openStart = 0

  /// Leftover samples of an incomplete frame, carried to the next feed.
  private var pending: [Float] = []
  /// Level (dB) of every completed frame, oldest first.
  private var levels: [Float] = []
  /// First frame index of the current silent run, if one is open.
  private var silentFrom: Int?
  /// The current run was already checked once for a pause cut.
  private var checkedRun = false

  public init(config: Config = Config()) {
    self.config = config
  }

  /// Feed newly captured samples (any chunk size). Returns the cuts decided
  /// by this call, ascending.
  public mutating func feed(_ samples: [Float]) -> [Cut] {
    pending.append(contentsOf: samples)
    var cuts: [Cut] = []
    while pending.count >= frameSamples {
      let frame = Array(pending.prefix(frameSamples))
      pending.removeFirst(frameSamples)
      levels.append(Self.level(frame))
      evaluate(frameIndex: levels.count - 1, cuts: &cuts)
    }
    return cuts
  }

  private var frameSamples: Int { config.frameMs * 16 }

  private mutating func evaluate(frameIndex index: Int, cuts: inout [Cut]) {
    let silent = levels[index] < threshold(upTo: index)
    if silent {
      if silentFrom == nil {
        silentFrom = index
        checkedRun = false
      }
      let runLength = index - silentFrom! + 1
      // One chance per run: when it first reaches pauseMs, cut at its middle
      // if the open segment is long enough.
      if !checkedRun && runLength * config.frameMs >= config.pauseMs {
        checkedRun = true
        let middle = (silentFrom! + runLength / 2) * frameSamples
        if (middle - openStart) / 16 >= config.minSegmentMs {
          cuts.append(Cut(sample: middle, forced: false))
          openStart = middle
        }
      }
    } else {
      silentFrom = nil
    }
    let openEnd = (index + 1) * frameSamples
    if (openEnd - openStart) / 16 >= config.maxSegmentMs {
      cuts.append(Cut(sample: forcedCut(before: index), forced: true))
      openStart = cuts.last!.sample
      silentFrom = nil
      checkedRun = false
    }
  }

  /// The 10th-percentile floor of recent frame levels plus marginDb, clamped.
  /// Below 25 frames there is no reliable floor: use the loudest threshold.
  private func threshold(upTo index: Int) -> Float {
    let first = max(0, index - config.floorWindowFrames + 1)
    let window = levels[first...index]
    guard window.count >= 25 else { return config.maxThresholdDb }
    let sorted = window.sorted()
    let floor = sorted[(sorted.count - 1) / 10]
    return min(config.maxThresholdDb, max(config.minThresholdDb, floor + config.marginDb))
  }

  /// The centre of the quietest 100 ms (5-frame) window inside the last
  /// forcedSearchMs before and including frame `index`.
  private func forcedCut(before index: Int) -> Int {
    let searchFrames = config.forcedSearchMs / config.frameMs
    let first = max(0, index - searchFrames + 1)
    guard index - first + 1 >= 5 else { return (index + 1) * frameSamples }
    var bestStart = first
    var bestMean = Float.greatestFiniteMagnitude
    if first <= index - 4 {
      for start in first...(index - 4) {
        let mean = levels[start...(start + 4)].reduce(0, +) / 5
        if mean < bestMean {
          bestMean = mean
          bestStart = start
        }
      }
    }
    return (bestStart + 2) * frameSamples
  }

  /// Frame level in dBFS: 20·log10(max(rms, 1e-7)).
  private static func level(_ frame: [Float]) -> Float {
    var sum: Float = 0
    for sample in frame { sum += sample * sample }
    return 20 * log10(max((sum / Float(frame.count)).squareRoot(), 1e-7))
  }
}
