// CONCETTO FORK (the click, 2026-11-21): a short sound in the glasses'
// speakers when a frame press is taken, and when a video starts and stops, so
// the wearer knows without looking at the phone. A still takes seconds to
// cross, and the glasses' own light is all they had.
//
// The glasses are a Bluetooth headset to the phone. The app's capture
// keep-alive holds the audio session as play-and-record without Bluetooth
// output, so the click would come from the phone's speaker. For the click,
// the session is allowed A2DP (the route a headset plays on), and it is put
// back as it was when the click ends. A session already playing to the
// glasses (the voice answering) is left alone. The tones are made here, with
// no file shipped.

import AVFoundation
import Foundation

@MainActor
final class GlassesClick {
  static let shared = GlassesClick()

  private var player: AVAudioPlayer?
  private var saved: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private var restore: Task<Void, Never>?
  private var sounds: [String: Data] = [:]

  /// Plays `kind` (`shutter`, `start` or `stop`). Answers whether it began;
  /// a click that cannot play is silent, never an error.
  func play(_ kind: String) -> Bool {
    guard let data = sound(kind) else { return false }
    routeToGlasses()
    do {
      let player = try AVAudioPlayer(data: data)
      player.volume = 0.6
      player.prepareToPlay()
      guard player.play() else {
        putBack(after: 0)
        return false
      }
      self.player = player
      putBack(after: player.duration + 0.15)
      return true
    } catch {
      putBack(after: 0)
      return false
    }
  }

  // MARK: - The route

  private func routeToGlasses() {
    restore?.cancel()
    restore = nil
    let audio = AVAudioSession.sharedInstance()
    // Playback already reaches a headset (the voice is speaking): leave it.
    guard audio.category == .playAndRecord else { return }
    if saved == nil {
      saved = (audio.category, audio.mode, audio.categoryOptions)
    }
    var options = audio.categoryOptions
    guard !options.contains(.allowBluetoothA2DP) else { return }
    options.insert(.allowBluetoothA2DP)
    try? audio.setCategory(.playAndRecord, mode: audio.mode, options: options)
  }

  private func putBack(after seconds: Double) {
    restore?.cancel()
    restore = Task { @MainActor [weak self] in
      if seconds > 0 {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      }
      guard let self, !Task.isCancelled else { return }
      self.player = nil
      guard let (category, mode, options) = self.saved else { return }
      self.saved = nil
      let audio = AVAudioSession.sharedInstance()
      // Only what the click changed is put back: a session someone else has
      // moved on since is theirs.
      guard audio.category == category, audio.mode == mode else { return }
      try? audio.setCategory(category, mode: mode, options: options)
    }
  }

  // MARK: - The sounds

  private func sound(_ kind: String) -> Data? {
    if let made = sounds[kind] { return made }
    let tones: [(frequency: Double, seconds: Double)]
    switch kind {
    case "start": tones = [(880, 0.07), (1320, 0.09)]
    case "stop": tones = [(1320, 0.07), (880, 0.09)]
    default: tones = [(2000, 0.035)]
    }
    let made = Self.wav(tones)
    sounds[kind] = made
    return made
  }

  /// 16-bit mono PCM at 22.05 kHz: each tone a sine with a fast attack and an
  /// exponential fall, so it reads as a click, not a beep.
  private static func wav(_ tones: [(frequency: Double, seconds: Double)]) -> Data {
    let rate = 22_050.0
    var samples: [Int16] = []
    for tone in tones {
      let count = Int(tone.seconds * rate)
      for i in 0..<count {
        let t = Double(i) / rate
        let attack = min(1, Double(i) / (rate * 0.002))
        let fall = exp(-t / (tone.seconds / 4))
        let value = sin(2 * .pi * tone.frequency * t) * attack * fall * 0.8
        samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
      }
      // A breath between tones.
      samples.append(contentsOf: [Int16](repeating: 0, count: Int(rate * 0.015)))
    }
    let dataBytes = samples.count * 2
    var data = Data()
    func put<T>(_ value: T) {
      withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    put(UInt32(36 + dataBytes).littleEndian)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    put(UInt32(16).littleEndian)
    put(UInt16(1).littleEndian)  // PCM
    put(UInt16(1).littleEndian)  // mono
    put(UInt32(rate).littleEndian)
    put(UInt32(rate * 2).littleEndian)  // bytes a second
    put(UInt16(2).littleEndian)  // bytes a frame
    put(UInt16(16).littleEndian)  // bits a sample
    data.append(contentsOf: Array("data".utf8))
    put(UInt32(dataBytes).littleEndian)
    for sample in samples { put(sample.littleEndian) }
    return data
  }
}
