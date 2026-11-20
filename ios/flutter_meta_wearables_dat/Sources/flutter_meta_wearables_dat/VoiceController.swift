import AVFoundation
import Flutter
import Foundation
import MWDATCore
import MWDATSpeech

// CONCETTO FORK (voice on camera glasses).
//
// "Hey Meta, start Chronotope" on glasses with no display, answered by the
// phone. After Meta's BirdSpotter sample (facebook/meta-wearables-dat-ios
// 1.0.1, samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesVoiceRepository.swift
// and the speech half of DatGlassesSessionRepository.swift):
//
// - The launch arrives on a `VoiceInvocationsStream`, a Wearables-level
//   channel opened once the app is registered and started on the active pair.
//   Every `LaunchApp` is answered at once (Meta AI holds the launch open until
//   it is), then handed to Dart. A channel that errors is reopened with a
//   backoff: a drop arrives on the error publisher, not by the stream ending.
// - The question is heard by the glasses themselves: `MWDATSpeech` transcribes
//   on the device, inside this plugin's device session, and each result comes
//   back as an event. It needs Meta's microphone permission
//   (`requestMicrophonePermission`), granted ahead of time in the app.
// - The answer is spoken by the phone (`AVSpeechSynthesizer`), which plays on
//   the glasses' speakers like any other Bluetooth audio. The audio session is
//   put back the way it was found when the phone stops speaking.
//
// Dart reaches it through `voiceListen`, `speechStart`, `speechStop`, `speak`
// and `speakStop`, and one event channel, `flutter_meta_wearables_dat/voice_events`.
// Every event is a map with a `type`: `channel`, `launch`, `speech_state`,
// `transcript` or `error`.

/// Resolves one waiting start exactly once, from the main actor (the capture
/// session's OneShot, which is private to its file).
@MainActor
private final class VoiceOnce {
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func resolve(_ value: Bool) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

/// The voice event channel. Flutter calls it on the main thread, and the
/// controller sends from the main actor.
final class VoiceEventStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func send(_ event: [String: Any]) {
    sink?(event)
  }
}

@MainActor
final class VoiceController: NSObject, AVSpeechSynthesizerDelegate {
  typealias SessionProvider = @MainActor () async throws -> DeviceSession
  typealias PairProvider = @MainActor () -> DeviceIdentifier?

  private let sessionProvider: SessionProvider
  private let activePair: PairProvider
  private let events: VoiceEventStreamHandler

  // The launch channel.
  private var channelTask: Task<Void, Never>?
  private var channel: VoiceInvocationsStream?
  private var listeningOn: DeviceIdentifier?
  private var dropSignal: AsyncStream<Void>.Continuation?

  // The glasses' own speech recogniser.
  private var speech: Speech?
  private var speechSession: DeviceSession?
  private var speechTokens: [any AnyListenerToken] = []
  private var speechHasStarted = false

  // The phone's voice.
  private let synthesizer = AVSpeechSynthesizer()
  private var speaking: CheckedContinuation<Bool, Never>?
  private var savedAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  /// BirdSpotter's reopen floor and ceiling.
  private let reopenFloorSeconds: Double = 0.5
  private let reopenCeilingSeconds: Double = 30

  init(
    sessionProvider: @escaping SessionProvider,
    activePair: @escaping PairProvider,
    events: VoiceEventStreamHandler
  ) {
    self.sessionProvider = sessionProvider
    self.activePair = activePair
    self.events = events
    super.init()
    synthesizer.delegate = self
  }

  // MARK: - "Hey Meta, start Chronotope"

  /// Opens the launch channel, once; later calls only move it to the active
  /// pair. Answers true.
  func listen() {
    if channelTask != nil {
      ensureListening()
      return
    }
    channelTask = Task { @MainActor [weak self] in
      var delay = self?.reopenFloorSeconds ?? 0.5
      while !Task.isCancelled {
        await Self.awaitRegistered()
        guard let self, !Task.isCancelled else { return }
        let dropped = await self.listenOnce()
        if !dropped { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        delay = min(delay * 2, self.reopenCeilingSeconds)
      }
    }
  }

  private static func awaitRegistered() async {
    if case .registered = Wearables.shared.registrationState { return }
    for await state in Wearables.shared.registrationStateStream() {
      if case .registered = state { return }
    }
  }

  /// One lease of the channel: open it, answer what arrives, follow the pairs,
  /// and return true when it drops.
  private func listenOnce() async -> Bool {
    let stream: VoiceInvocationsStream
    do {
      stream = try VoiceInvocationsStream(wearables: Wearables.shared)
    } catch {
      emit(["type": "channel", "state": "failed", "detail": String(describing: error)])
      return true
    }
    channel = stream
    let (drops, signal) = AsyncStream<Void>.makeStream()
    dropSignal = signal
    var tokens: [any AnyListenerToken] = []
    tokens.append(
      stream.invocationsPublisher.listen { [weak self] invocation in
        Task { @MainActor in await self?.answer(invocation) }
      })
    tokens.append(
      stream.errorPublisher.listen { [weak self] error in
        let detail = String(describing: error)
        Task { @MainActor in
          self?.emit(["type": "channel", "state": "dropped", "detail": detail])
          signal.yield()
        }
      })

    let dropped = await withTaskGroup(of: Bool.self) { group in
      // A pair is listed a beat before its link is up, and a start asked in
      // that window fails: every list and link change asks again.
      group.addTask { @MainActor [weak self] in
        var linkTokens: [any AnyListenerToken] = []
        for await ids in Wearables.shared.devicesStream() {
          for token in linkTokens { await token.cancel() }
          linkTokens.removeAll()
          self?.ensureListening()
          for id in ids {
            guard let device = Wearables.shared.deviceForIdentifier(id) else { continue }
            linkTokens.append(
              device.addLinkStateListener { [weak self] _ in
                Task { @MainActor in self?.ensureListening() }
              })
          }
        }
        for token in linkTokens { await token.cancel() }
        return false
      }
      group.addTask {
        for await _ in drops { return true }
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }

    if listeningOn != nil { stream.stop() }
    channel = nil
    dropSignal = nil
    listeningOn = nil
    for token in tokens { await token.cancel() }
    return dropped
  }

  /// Starts the channel on the active pair, or moves it there. A failed start
  /// leaves `listeningOn` empty, so the next change asks again.
  private func ensureListening() {
    guard let channel, let pair = activePair(), pair != listeningOn else { return }
    if listeningOn != nil { channel.stop() }
    listeningOn = nil
    do {
      try channel.start(deviceIdentifier: pair)
      listeningOn = pair
      emit(["type": "channel", "state": "listening"])
    } catch {
      emit(["type": "channel", "state": "start_failed", "detail": String(describing: error)])
    }
  }

  /// Answered before Dart hears of it: Meta AI is waiting on the answer.
  private func answer(_ invocation: any VoiceInvocation) async {
    guard let launch = invocation as? LaunchApp else {
      emit(["type": "channel", "state": "ignored", "detail": String(describing: invocation)])
      return
    }
    let delivered = await launch.responseHandle.sendSuccess(actionOutput: nil)
    emit(["type": "launch", "answered": delivered])
  }

  // MARK: - Hearing the question

  /// Starts the glasses' recogniser in this plugin's device session. Answers
  /// once it is listening. Throws `SPEECH_UNAVAILABLE` on a pair with none,
  /// `SESSION_FAILED`, or `SPEECH_FAILED`.
  func startSpeech() async throws {
    if speech != nil, speechHasStarted { return }
    let session: DeviceSession
    do {
      session = try await sessionProvider()
    } catch {
      throw CaptureFailure(code: "SESSION_FAILED", detail: String(describing: error))
    }
    let attached: Speech?
    do {
      attached = try session.addSpeech()
    } catch {
      throw CaptureFailure(code: "SPEECH_FAILED", detail: String(describing: error))
    }
    guard let speech = attached else {
      throw CaptureFailure(code: "SPEECH_UNAVAILABLE", detail: "this pair has no on-device speech")
    }
    self.speech = speech
    speechSession = session
    speechHasStarted = false

    let started: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let once = VoiceOnce(continuation)
      speechTokens.append(
        speech.statePublisher.listen { [weak self] state in
          Task { @MainActor in
            guard let self else { return }
            self.emit(["type": "speech_state", "state": String(describing: state)])
            if state == .started {
              self.speechHasStarted = true
              once.resolve(true)
            } else if state == .stopped, self.speechHasStarted {
              self.speechHasStarted = false
            }
          }
        })
      speechTokens.append(
        speech.transcriptionPublisher.listen { [weak self] result in
          let text = result.text
          let isFinal = result.isFinal
          let confidence = Double(result.confidence)
          Task { @MainActor in
            self?.emit([
              "type": "transcript", "text": text, "final": isFinal, "confidence": confidence,
            ])
          }
        })
      speechTokens.append(
        speech.errorPublisher.listen { [weak self] error in
          let code = Self.code(for: error)
          let detail = error.description
          Task { @MainActor in
            self?.emit(["type": "error", "where": "speech", "code": code, "detail": detail])
            once.resolve(false)
          }
        })
      speech.start()
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        once.resolve(false)
      }
    }
    if !started {
      await stopSpeech()
      throw CaptureFailure(code: "SPEECH_FAILED", detail: "the recogniser did not start")
    }
  }

  /// Puts the recogniser down. The device session stays: it is the plugin's,
  /// and a capture session may be on it.
  func stopSpeech() async {
    let (speech, session, tokens) = (self.speech, speechSession, speechTokens)
    self.speech = nil
    speechSession = nil
    speechTokens = []
    speechHasStarted = false
    for token in tokens { await token.cancel() }
    speech?.stop()
    if speech != nil, let session { try? session.removeSpeech() }
  }

  nonisolated static func code(for error: SpeechError) -> String {
    switch error {
    case .deviceDisconnected: return "DEVICE_DISCONNECTED"
    case .invalidState: return "SPEECH_INVALID_STATE"
    case .unavailable: return "SPEECH_UNAVAILABLE"
    case .alreadyListening: return "SPEECH_BUSY"
    case .startFailed: return "SPEECH_FAILED"
    case .unexpectedError: return "SPEECH_ERROR"
    @unknown default: return "SPEECH_ERROR"
    }
  }

  // MARK: - Speaking the answer

  /// Speaks `text` and answers when it has been said (true) or cut off
  /// (false). A second call cuts the first off.
  func speak(_ text: String, language: String?) async -> Bool {
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    finishSpeaking(false)
    takeAudio()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language ?? AVSpeechSynthesisVoice.currentLanguageCode())
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    let said: Bool = await withCheckedContinuation { continuation in
      speaking = continuation
      synthesizer.speak(utterance)
    }
    if !synthesizer.isSpeaking { giveAudioBack() }
    return said
  }

  func stopSpeaking() {
    if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    finishSpeaking(false)
    giveAudioBack()
  }

  private func finishSpeaking(_ said: Bool) {
    speaking?.resume(returning: said)
    speaking = nil
  }

  /// Spoken audio that ducks the rest and plays on the glasses (A2DP is the
  /// route a playback session takes to a Bluetooth headset).
  private func takeAudio() {
    let audio = AVAudioSession.sharedInstance()
    if savedAudio == nil {
      savedAudio = (audio.category, audio.mode, audio.categoryOptions)
    }
    do {
      try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetoothA2DP])
      try audio.setActive(true)
    } catch {
      emit(["type": "error", "where": "speak", "code": "AUDIO_FAILED", "detail": String(describing: error)])
    }
  }

  private func giveAudioBack() {
    guard let (category, mode, options) = savedAudio else { return }
    savedAudio = nil
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(category, mode: mode, options: options)
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finishSpeaking(true) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.finishSpeaking(false) }
  }

  // MARK: -

  private func emit(_ event: [String: Any]) {
    events.send(event)
  }
}
