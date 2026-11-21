// CONCETTO FORK (glasses video, 2026-11-21): the glasses' stream written to an
// MP4 on the phone, for a video site walk. Zach, 11-21: "i need photo and
// video capture working beautifully".
//
// The stream comes from the capture session's video camera (HEVC, with the
// glasses' own microphone as 16 kHz PCM when asked). HEVC frames that arrive
// compressed are written as they are (no second encode on the phone); frames
// that arrive as pixels are encoded to H.264. Audio is encoded to AAC. The
// file starts at the first key frame, and the microphone is placed against
// the video by when each first arrived, since the two streams' clocks are
// not promised to be one.
//
// Everything runs on one serial queue, so the kit's callbacks can append from
// any thread.

import AVFoundation
import CoreMedia
import Foundation
import MWDATCamera
import UIKit

final class GlassesVideoRecorder: @unchecked Sendable {
  struct Summary: Sendable {
    let url: URL
    let videoFrames: Int
    let audioBuffers: Int
    let droppedFrames: Int
    let durationMs: Int
    let bytes: Int
    let kind: String
    let width: Int
    let height: Int
  }

  struct Failure: Error {
    let code: String
    let detail: String
  }

  private let url: URL
  private let withAudio: Bool
  private let queue = DispatchQueue(label: "concetto.glasses.video-recorder")

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var failure: Failure?
  private var finished = false

  /// The first video frame written: its time, and when it arrived here.
  private var videoStart: CMTime = .invalid
  private var videoStartHost: Double = 0
  private var lastVideoTime: CMTime = .invalid
  /// The first audio buffer: its time, and when it arrived here.
  private var audioStart: CMTime = .invalid
  private var audioStartHost: Double = 0

  private var videoFrames = 0
  private var audioBuffers = 0
  private var droppedFrames = 0
  private var kind = "none"
  private var width = 0
  private var height = 0

  init(url: URL, withAudio: Bool) {
    self.url = url
    self.withAudio = withAudio
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Appending

  func append(video frame: VideoFrame) {
    let arrived = CACurrentMediaTime()
    queue.async { [self] in
      guard !finished, failure == nil else { return }
      let sample = frame.sampleBuffer
      if writer == nil {
        // The file starts at a key frame, or nothing before it can be read.
        guard Self.isKeyFrame(sample) else {
          droppedFrames += 1
          return
        }
        do {
          try startWriter(with: sample)
        } catch let error as Failure {
          failure = error
          return
        } catch {
          failure = Failure(code: "WRITER_FAILED", detail: String(describing: error))
          return
        }
        videoStart = CMSampleBufferGetPresentationTimeStamp(sample)
        videoStartHost = arrived
        writer?.startSession(atSourceTime: videoStart)
      }
      guard let input = videoInput, input.isReadyForMoreMediaData else {
        droppedFrames += 1
        return
      }
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      // A frame that goes back in time would end the file.
      if lastVideoTime.isValid, CMTimeCompare(time, lastVideoTime) <= 0 {
        droppedFrames += 1
        return
      }
      if input.append(sample) {
        videoFrames += 1
        lastVideoTime = time
      } else {
        droppedFrames += 1
        if let error = writer?.error {
          failure = Failure(code: "WRITER_FAILED", detail: String(describing: error))
        }
      }
    }
  }

  func append(audio frame: AudioFrame) {
    guard withAudio else { return }
    let arrived = CACurrentMediaTime()
    queue.async { [self] in
      guard !finished, failure == nil, let writer, let input = audioInput,
        videoStart.isValid
      else { return }
      if !audioStart.isValid {
        audioStart = frame.presentationTimeStamp
        audioStartHost = arrived
      }
      // Placed against the video by arrival: the video's first frame time,
      // plus how long after it the first audio arrived, plus the audio's own
      // progress since.
      let offset = CMTime(seconds: audioStartHost - videoStartHost, preferredTimescale: 48_000)
      let since = CMTimeSubtract(frame.presentationTimeStamp, audioStart)
      let time = CMTimeAdd(CMTimeAdd(videoStart, offset), since)
      guard CMTimeCompare(time, videoStart) >= 0, input.isReadyForMoreMediaData,
        writer.status == .writing,
        let sample = Self.sampleBuffer(frame.pcmBuffer, at: time)
      else { return }
      if input.append(sample) { audioBuffers += 1 }
    }
  }

  // MARK: - Finishing

  func finish() async -> Result<Summary, Failure> {
    await withCheckedContinuation { (continuation: CheckedContinuation<Result<Summary, Failure>, Never>) in
      queue.async { [self] in
        finished = true
        if let failure {
          try? FileManager.default.removeItem(at: url)
          continuation.resume(returning: .failure(failure))
          return
        }
        guard let writer, writer.status == .writing, videoFrames > 0 else {
          writer?.cancelWriting()
          try? FileManager.default.removeItem(at: url)
          continuation.resume(returning: .failure(Failure(
            code: "NO_FRAMES", detail: "no frame reached the file (\(droppedFrames) dropped)")))
          return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if lastVideoTime.isValid { writer.endSession(atSourceTime: lastVideoTime) }
        writer.finishWriting { [self] in
          queue.async { [self] in
            guard writer.status == .completed else {
              try? FileManager.default.removeItem(at: url)
              continuation.resume(returning: .failure(Failure(
                code: "WRITER_FAILED", detail: String(describing: writer.error))))
              return
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let duration = lastVideoTime.isValid && videoStart.isValid
              ? Int(CMTimeSubtract(lastVideoTime, videoStart).seconds * 1000) : 0
            continuation.resume(returning: .success(Summary(
              url: url, videoFrames: videoFrames, audioBuffers: audioBuffers,
              droppedFrames: droppedFrames, durationMs: duration, bytes: bytes,
              kind: kind, width: width, height: height)))
          }
        }
      }
    }
  }

  /// Drops the file: the walk was abandoned, or the session went away.
  func discard() {
    queue.async { [self] in
      finished = true
      writer?.cancelWriting()
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - The writer

  private func startWriter(with first: CMSampleBuffer) throws {
    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    } catch {
      throw Failure(code: "WRITER_FAILED", detail: String(describing: error))
    }
    let video: AVAssetWriterInput
    if let pixels = CMSampleBufferGetImageBuffer(first) {
      kind = "pixels"
      width = CVPixelBufferGetWidth(pixels)
      height = CVPixelBufferGetHeight(pixels)
      video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ])
    } else if let format = CMSampleBufferGetFormatDescription(first) {
      kind = "compressed"
      let size = CMVideoFormatDescriptionGetDimensions(format)
      width = Int(size.width)
      height = Int(size.height)
      video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    } else {
      throw Failure(code: "NO_FORMAT", detail: "the first frame carried no format")
    }
    video.expectsMediaDataInRealTime = true
    guard writer.canAdd(video) else {
      throw Failure(code: "WRITER_FAILED", detail: "the writer would not take the video (\(kind))")
    }
    writer.add(video)
    if withAudio {
      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
      ])
      audio.expectsMediaDataInRealTime = true
      if writer.canAdd(audio) {
        writer.add(audio)
        audioInput = audio
      }
    }
    guard writer.startWriting() else {
      throw Failure(code: "WRITER_FAILED", detail: String(describing: writer.error))
    }
    self.writer = writer
    videoInput = video
  }

  private static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
    // A frame of pixels has no key frames to wait for.
    if CMSampleBufferGetImageBuffer(sample) != nil { return true }
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[CFString: Any]],
      let first = attachments.first
    else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }

  /// The microphone's PCM as a sample buffer the AAC input takes.
  private static func sampleBuffer(_ pcm: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
    var description = pcm.format.streamDescription.pointee
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        == noErr,
      let format
    else { return nil }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(description.mSampleRate)),
      presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    guard
      CMSampleBufferSetDataBufferFromAudioBufferList(
        sample, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
        bufferList: pcm.audioBufferList) == noErr
    else { return nil }
    return sample
  }
}
