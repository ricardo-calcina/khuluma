import AudioToolbox
import AVFoundation
import Foundation

/// Decodes an audio or video file (m4a, mp3, wav, aac, flac, mp4, mov) to the
/// 16 kHz mono 16-bit WAV the daemon reads, streamed to disk so an hour-long
/// voice memo never sits in memory. Like the CLI's ffmpeg step
/// (`apad=whole_dur=1.05`), short clips are padded with silence to 1.05 s.
public enum AudioFileDecoder {
  public enum DecodeError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case noAudio
    case write(String)

    public var errorDescription: String? {
      switch self {
      case .unreadable(let detail): return "could not decode audio: \(detail)"
      case .noAudio: return "no audio found"
      case .write(let detail): return "could not write decoded audio: \(detail)"
      }
    }
  }

  public struct Decoded: Equatable, Sendable {
    /// The private WAV (16 kHz mono s16le, padded); the caller removes it.
    public let wav: URL
    /// Samples decoded from the file, before padding.
    public let decodedSamples: Int
    /// Samples in the WAV, after padding.
    public let samples: Int
    /// The WAV's length as the CLI's `audio_duration_ms` reports it.
    public var durationMs: Int { AudioPrep.ffprobeDurationMs(sampleCount: samples) }
  }

  /// `apad=whole_dur=1.05` at 16 kHz.
  public static let minimumSamples = 16_800

  public static func decode(_ input: URL, to wav: URL) throws -> Decoded {
    let writer = try StreamingWAVWriter(url: wav)
    var finished = false
    defer { if !finished { writer.abandon() } }
    let decoded = try readAll(input) { try writer.append($0) }
    guard decoded > 0 else { throw DecodeError.noAudio }
    if decoded < minimumSamples {
      try writer.append([Int16](repeating: 0, count: minimumSamples - decoded))
    }
    try writer.finish()
    finished = true
    return Decoded(wav: wav, decodedSamples: decoded, samples: max(decoded, minimumSamples))
  }

  /// Streams every 16 kHz mono sample of the file. ExtAudioFile (plain
  /// AudioToolbox, converting itself) handles wav, m4a, mp3, aac, flac, aiff
  /// and caf. Only what it can't open (video containers: mp4, mov) goes
  /// through AVAssetReader, which waits on Swift's cooperative pool inside
  /// `copyNextSampleBuffer`: call this from a plain thread or queue, never
  /// from a pool thread (async code), or a busy pool deadlocks it.
  static func readAll(_ input: URL, _ sink: ([Int16]) throws -> Void) throws -> Int {
    var file: ExtAudioFileRef?
    if ExtAudioFileOpenURL(input as CFURL, &file) == noErr, let file {
      defer { ExtAudioFileDispose(file) }
      if let total = try readExtAudioFile(file, sink) { return total }
    }
    return try readAsset(input, sink)
  }

  /// nil when the file has no audio ExtAudioFile can convert.
  private static func readExtAudioFile(_ file: ExtAudioFileRef, _ sink: ([Int16]) throws -> Void) throws -> Int? {
    var client = AudioStreamBasicDescription(
      mSampleRate: Double(AudioPrep.sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
      mReserved: 0)
    guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                  UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
      return nil
    }
    let capacity = 32_768
    var samples = [Int16](repeating: 0, count: capacity)
    var total = 0
    while true {
      var frames = UInt32(capacity)
      let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        return ExtAudioFileRead(file, &frames, &list)
      }
      guard status == noErr else {
        if total == 0 { return nil }
        throw DecodeError.unreadable("audio read error \(status)")
      }
      if frames == 0 { return total }
      total += Int(frames)
      try sink(Array(samples.prefix(Int(frames))))
    }
  }

  private static func readAsset(_ input: URL, _ sink: ([Int16]) throws -> Void) throws -> Int {
    let asset = AVURLAsset(url: input)
    guard let track = try loadAudioTrack(asset) else {
      throw DecodeError.unreadable("no audio track in \(input.lastPathComponent)")
    }
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw DecodeError.unreadable(error.localizedDescription)
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: AudioPrep.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw DecodeError.unreadable("unsupported audio format") }
    reader.add(output)
    guard reader.startReading() else {
      throw DecodeError.unreadable(reader.error?.localizedDescription ?? "cannot read \(input.lastPathComponent)")
    }
    var total = 0
    while let buffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      guard length > 0 else { continue }
      let count = length / 2
      var samples = [Int16](repeating: 0, count: count)
      let status = samples.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: raw.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw DecodeError.unreadable("audio buffer error \(status)") }
      total += samples.count
      try sink(samples)
    }
    if reader.status == .failed {
      throw DecodeError.unreadable(reader.error?.localizedDescription ?? "decoding failed")
    }
    return total
  }

  /// The synchronous accessor, on purpose: every async loader (including the
  /// completion-handler one) finishes on Swift's cooperative pool, so
  /// blocking on it from a pool thread (Swift Testing, async callers)
  /// deadlocks once the pool is busy. This loads on the calling thread.
  private static func loadAudioTrack(_ asset: AVURLAsset) throws -> AVAssetTrack? {
    asset.tracks(withMediaType: .audio).first
  }

  /// The last `windowMs` of a decoded WAV as its own WAV (the CLI's
  /// `ffmpeg -sseof`), read without loading the whole file.
  public static func writeTail(of decoded: Decoded, windowMs: Int, to url: URL) throws {
    let count = min(decoded.samples, windowMs * AudioPrep.sampleRate / 1000)
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: decoded.wav) } catch { throw DecodeError.write(error.localizedDescription) }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: UInt64(StreamingWAVWriter.headerSize + (decoded.samples - count) * 2))
      let data = try handle.read(upToCount: count * 2) ?? Data()
      let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      let writer = try StreamingWAVWriter(url: url)
      try writer.append(pcm)
      try writer.finish()
    } catch let error as DecodeError {
      throw error
    } catch {
      throw DecodeError.write(error.localizedDescription)
    }
  }
}

/// A 16 kHz mono s16le WAV written in pieces; sizes are patched on finish.
final class StreamingWAVWriter {
  static let headerSize = 44
  let url: URL
  private let handle: FileHandle
  private var dataBytes = 0

  init(url: URL) throws {
    self.url = url
    guard FileManager.default.createFile(atPath: url.path, contents: WAVEncoder.encode(pcm: []),
                                         attributes: [.posixPermissions: 0o600]),
          let handle = FileHandle(forWritingAtPath: url.path) else {
      throw AudioFileDecoder.DecodeError.write("cannot create \(url.path)")
    }
    self.handle = handle
    handle.seekToEndOfFile()
  }

  func append(_ pcm: [Int16]) throws {
    guard !pcm.isEmpty else { return }
    let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
    do { try handle.write(contentsOf: data) } catch { throw AudioFileDecoder.DecodeError.write(error.localizedDescription) }
    dataBytes += data.count
  }

  func finish() throws {
    // RIFF sizes are 32-bit: ~37 hours of 16 kHz mono.
    guard dataBytes <= Int(UInt32.max) - 36 else { throw AudioFileDecoder.DecodeError.write("audio too long") }
    do {
      var riff = Data(), size = Data()
      riff.appendLE(UInt32(36 + dataBytes))
      size.appendLE(UInt32(dataBytes))
      try handle.seek(toOffset: 4)
      try handle.write(contentsOf: riff)
      try handle.seek(toOffset: 40)
      try handle.write(contentsOf: size)
      try handle.close()
    } catch {
      throw AudioFileDecoder.DecodeError.write(error.localizedDescription)
    }
  }

  /// Closes and deletes a half-written file.
  func abandon() {
    try? handle.close()
    try? FileManager.default.removeItem(at: url)
  }
}

/// Random access to a decoded WAV's samples, for chunking.
final class WAVSampleReader {
  private let handle: FileHandle
  private let count: Int

  init(_ decoded: AudioFileDecoder.Decoded) throws {
    do { handle = try FileHandle(forReadingFrom: decoded.wav) } catch {
      throw AudioFileDecoder.DecodeError.write(error.localizedDescription)
    }
    count = decoded.samples
  }

  deinit { try? handle.close() }

  func samples(_ range: Range<Int>) throws -> [Int16] {
    let clamped = range.clamped(to: 0..<count)
    guard !clamped.isEmpty else { return [] }
    try handle.seek(toOffset: UInt64(StreamingWAVWriter.headerSize + clamped.lowerBound * 2))
    let data = try handle.read(upToCount: clamped.count * 2) ?? Data()
    return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
  }
}
