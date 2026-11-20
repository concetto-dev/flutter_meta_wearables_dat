import Flutter
import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs

// CONCETTO FORK (capture session).
//
// One glasses session for taking photos, after Meta's BirdSpotter sample
// (facebook/meta-wearables-dat-ios 1.0.1,
// samples/BirdSpotter/BirdSpotter/Data/Dat/DatGlassesSessionRepository.swift):
//
// - The camera is attached once, with a small HEVC stream whose only job is to
//   wake the sensor: `Photo.start()` on a cold camera sits at `starting`
//   forever. When the stream reports `.streaming` the standalone `Photo` is
//   started, and when that reports `.started` the stream is put down, because
//   frames and stills compete for the sensor. HEVC, not raw: the SDK pauses a
//   raw stream when the app leaves the foreground.
// - Each still is `camera.photo.capturePhoto(resolution:quality:)`. Its bytes
//   arrive on `photoDataPublisher` after the Bluetooth crossing (about a second
//   at medium). A crossing puts the session's other capabilities down (the
//   display and the inputs), so both are brought back after it.
// - On Meta Ray-Ban Display the phone draws its own card (`addDisplay`) and
//   holds the display for the whole session. Taps on the card's buttons come
//   back as events. Glasses without a display skip it.
// - Inputs (the capture button, the temple, the action button) come back as
//   events. The Neural Band is left to the wearer, because it moves focus on
//   the card.
//
// Dart reaches it through four methods (`captureStart`, `captureStill`,
// `captureShow`, `captureStop`) and one event channel,
// `flutter_meta_wearables_dat/capture_events`. Every event is a map with a
// `type`: `state`, `stream`, `photo_state`, `progress`, `tap`, `input`,
// `display`, `inputs` or `error`.

/// A failure Dart sees as a `PlatformException` with this code.
struct CaptureFailure: Error {
  let code: String
  let detail: String
}

/// Resolves one waiting call exactly once, from the main actor.
@MainActor
private final class OneShot<T> {
  private var continuation: CheckedContinuation<T, Never>?

  init(_ continuation: CheckedContinuation<T, Never>) {
    self.continuation = continuation
  }

  func resolve(_ value: T) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

/// What the phone asks the display to show: a heading, body lines, a quiet
/// footer line and up to three buttons.
struct CaptureCard {
  struct Action {
    let id: String
    let label: String
    let icon: String?
    let primary: Bool
  }

  let title: String
  let lines: [String]
  let meta: String?
  let actions: [Action]

  init?(_ map: [String: Any]) {
    guard let title = map["title"] as? String else { return nil }
    self.title = title
    lines = (map["lines"] as? [String]) ?? []
    meta = map["meta"] as? String
    let raw = (map["buttons"] as? [[String: Any]]) ?? []
    actions = raw.prefix(3).compactMap { item in
      guard let id = item["id"] as? String, let label = item["label"] as? String else {
        return nil
      }
      return Action(
        id: id,
        label: label,
        icon: item["icon"] as? String,
        primary: (item["primary"] as? Bool) ?? false
      )
    }
  }
}

/// The capture session's event channel. Flutter calls it on the main thread,
/// and the controller sends from the main actor.
final class CaptureEventStreamHandler: NSObject, FlutterStreamHandler {
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
final class CaptureSessionController {
  typealias SessionProvider = @MainActor () async throws -> DeviceSession
  typealias Release = @MainActor () async -> Void

  private let sessionProvider: SessionProvider
  private let releasePreview: Release
  private let endSession: Release
  private let events: CaptureEventStreamHandler

  private var session: DeviceSession?
  private var camera: Camera?
  private var display: Display?
  private var inputs: Inputs?
  private var inputsDrain: Task<Void, Never>?
  private var cameraTokens: [any AnyListenerToken] = []
  private var displayTokens: [any AnyListenerToken] = []
  private var inputsTokens: [any AnyListenerToken] = []

  /// Bumped by every start and stop, so a callback from an earlier session
  /// drops itself.
  private var generation = 0
  private var wantsDisplay = false
  private var wantsInputs = false
  private var cameraHasStarted = false
  private var photoStartRequested = false
  private var photoStarted = false
  private var streamPutDown = false
  private var inputsHasActivated = false
  private var displayHasStarted = false
  private var displayRestarts = 0
  private var lastCard: CaptureCard?
  private var readyWaiters: [OneShot<Bool>] = []
  private var pendingPhoto: OneShot<Result<Data, CaptureFailure>>?

  /// How long a start may take: the session, the camera, the stream's first
  /// frames and the photo capability. BirdSpotter's own start is a few
  /// seconds; the session alone is allowed 20 by the plugin.
  private let readyTimeoutSeconds: Double = 25
  /// The backstop for a crossing that dies with the link still up
  /// (BirdSpotter's `photoTransferTimeout`).
  private let photoTimeoutSeconds: Double = 15
  /// BirdSpotter's `sensorRevivalDelay` and `sensorRevivalAttempts`.
  private let revivalDelaySeconds: Double = 0.75
  private let revivalAttempts = 3

  init(
    sessionProvider: @escaping SessionProvider,
    releasePreview: @escaping Release,
    endSession: @escaping Release,
    events: CaptureEventStreamHandler
  ) {
    self.sessionProvider = sessionProvider
    self.releasePreview = releasePreview
    self.endSession = endSession
    self.events = events
  }

  // MARK: - Start and stop

  /// Starts the session, or refreshes what it carries when it is already up.
  /// Answers once a still can be taken.
  func start(display: Bool, inputs: Bool) async throws -> [String: Any] {
    if camera != nil, photoStarted {
      wantsDisplay = display
      wantsInputs = inputs
      attachExtrasIfNeeded()
      return status()
    }
    await stop(endingSession: false)
    generation += 1
    let gen = generation
    wantsDisplay = display
    wantsInputs = inputs

    // The plugin's own preview stream holds the camera; it gives it up first.
    await releasePreview()
    let session: DeviceSession
    do {
      session = try await sessionProvider()
    } catch {
      throw CaptureFailure(code: "SESSION_FAILED", detail: String(describing: error))
    }
    guard gen == generation else {
      throw CaptureFailure(code: "STOPPED", detail: "stopped while starting")
    }
    self.session = session

    let config = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 2)
    let attached: Camera?
    do {
      attached = try session.addCamera(config: config)
    } catch {
      throw CaptureFailure(code: "CAMERA_FAILED", detail: String(describing: error))
    }
    guard let camera = attached else {
      throw CaptureFailure(code: "CAMERA_FAILED", detail: "the camera would not attach")
    }
    self.camera = camera
    observeCamera(camera, gen: gen)
    emit(["type": "state", "state": "starting"])
    camera.stream.start()

    let ready = await waitUntilReady()
    guard gen == generation else {
      throw CaptureFailure(code: "STOPPED", detail: "stopped while starting")
    }
    guard ready else {
      await stop(endingSession: false)
      throw CaptureFailure(code: "START_TIMEOUT", detail: "the camera did not come up")
    }
    return status()
  }

  /// Puts everything down. The device session is the plugin's and stays up
  /// unless `endingSession`, which hands the glasses back to the wearer.
  func stop(endingSession: Bool) async {
    let wasRunning = camera != nil || display != nil || inputs != nil
    generation += 1
    let (display, inputs, camera, session) = (self.display, self.inputs, self.camera, self.session)
    self.display = nil
    self.inputs = nil
    self.camera = nil
    self.session = nil
    inputsDrain?.cancel()
    inputsDrain = nil
    pendingPhoto?.resolve(.failure(CaptureFailure(code: "STOPPED", detail: "the session stopped")))
    pendingPhoto = nil
    let waiters = readyWaiters
    readyWaiters = []
    for waiter in waiters { waiter.resolve(false) }
    cameraHasStarted = false
    photoStartRequested = false
    photoStarted = false
    streamPutDown = false
    inputsHasActivated = false
    displayHasStarted = false
    displayRestarts = 0
    lastCard = nil

    let tokens = cameraTokens + displayTokens + inputsTokens
    cameraTokens = []
    displayTokens = []
    inputsTokens = []
    for token in tokens { await token.cancel() }

    display?.stop()
    if inputs != nil, let session {
      try? session.removeInputs()
    }
    camera?.stop()
    if endingSession { await endSession() }
    if wasRunning { emit(["type": "state", "state": "stopped"]) }
  }

  private func waitUntilReady() async -> Bool {
    if photoStarted { return true }
    let seconds = readyTimeoutSeconds
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let shot = OneShot(continuation)
      readyWaiters.append(shot)
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        shot.resolve(false)
      }
    }
  }

  private func status() -> [String: Any] {
    [
      "ready": photoStarted,
      "display": display != nil,
      "inputs": inputs != nil,
      "supportsDisplay": session?.device?.supportsDisplay() ?? false,
    ]
  }

  // MARK: - The camera

  private func observeCamera(_ camera: Camera, gen: Int) {
    cameraTokens.append(
      camera.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.cameraChanged(state, gen: gen) }
      })
    cameraTokens.append(
      camera.stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.streamChanged(state, gen: gen) }
      })
    cameraTokens.append(
      camera.photo.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.photoChanged(state, gen: gen) }
      })
    cameraTokens.append(
      camera.photo.photoDataPublisher.listen { [weak self] capture in
        let bytes = capture.imageData
        Task { @MainActor in self?.photoArrived(bytes, gen: gen) }
      })
    cameraTokens.append(
      camera.photo.errorPublisher.listen { [weak self] error in
        let code = CaptureSessionController.code(for: error)
        let detail = error.description
        Task { @MainActor in self?.photoFailed(code: code, detail: detail, gen: gen) }
      })
    cameraTokens.append(
      camera.photo.transferProgressPublisher.listen { [weak self] progress in
        let fraction = progress.fraction
        Task { @MainActor in
          guard let self, gen == self.generation else { return }
          self.emit(["type": "progress", "fraction": fraction])
        }
      })
  }

  private func cameraChanged(_ state: CameraState, gen: Int) {
    guard gen == generation else { return }
    if state == .started {
      cameraHasStarted = true
    } else if state == .stopped {
      // A camera is born stopped; only one that was up and went down means
      // the glasses are gone.
      guard cameraHasStarted else { return }
      emit(["type": "state", "state": "camera_lost"])
      Task { @MainActor [weak self] in
        guard let self, gen == self.generation else { return }
        await self.stop(endingSession: false)
      }
    }
  }

  private func streamChanged(_ state: StreamState, gen: Int) {
    guard gen == generation, let camera else { return }
    emit(["type": "stream", "state": String(describing: state)])
    guard state == .streaming else { return }
    // The sensor is awake: start the still, and attach what waits on the
    // device being there.
    if !photoStartRequested {
      photoStartRequested = true
      camera.photo.start()
    }
    attachExtrasIfNeeded()
  }

  private func photoChanged(_ state: PhotoState, gen: Int) {
    guard gen == generation, let camera else { return }
    emit(["type": "photo_state", "state": String(describing: state)])
    if state == .started {
      // Published more than once; everything below is idempotent.
      photoStarted = true
      if !streamPutDown {
        streamPutDown = true
        camera.stream.stop()
      }
      let waiters = readyWaiters
      readyWaiters = []
      for waiter in waiters { waiter.resolve(true) }
      emit(["type": "state", "state": "ready"])
    } else if state == .stopped, photoStarted {
      photoStarted = false
      pendingPhoto?.resolve(
        .failure(CaptureFailure(code: "PHOTO_STOPPED", detail: "the photo capability stopped")))
      pendingPhoto = nil
      emit(["type": "state", "state": "photo_stopped"])
    }
  }

  // MARK: - Stills

  func still(resolution: PhotoResolution, quality: PhotoQuality) async throws -> Data {
    guard let camera, photoStarted else {
      throw CaptureFailure(code: "PHOTO_NOT_READY", detail: "the camera is not up")
    }
    guard pendingPhoto == nil else {
      throw CaptureFailure(code: "PHOTO_BUSY", detail: "a photo is already crossing")
    }
    let gen = generation
    let seconds = photoTimeoutSeconds
    let result: Result<Data, CaptureFailure> = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<Data, CaptureFailure>, Never>) in
      let shot = OneShot(continuation)
      pendingPhoto = shot
      camera.photo.capturePhoto(resolution: resolution, quality: quality)
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        shot.resolve(
          .failure(CaptureFailure(code: "PHOTO_TIMEOUT", detail: "nothing arrived in \(Int(seconds)) s")))
      }
    }
    if gen == generation {
      pendingPhoto = nil
      // A crossing puts the display and the inputs down; bring them back.
      reviveExtras(gen: gen)
    }
    return try result.get()
  }

  private func photoArrived(_ bytes: Data, gen: Int) {
    guard gen == generation else { return }
    pendingPhoto?.resolve(.success(bytes))
    pendingPhoto = nil
  }

  private func photoFailed(code: String, detail: String, gen: Int) {
    guard gen == generation else { return }
    emit(["type": "error", "where": "photo", "code": code, "detail": detail])
    pendingPhoto?.resolve(.failure(CaptureFailure(code: code, detail: detail)))
    pendingPhoto = nil
  }

  nonisolated static func code(for error: PhotoError) -> String {
    switch error {
    case .notReady: return "PHOTO_NOT_READY"
    case .busy: return "PHOTO_BUSY"
    case .deviceHealthCritical: return "DEVICE_HEALTH"
    case .permissionDenied: return "PERMISSION_DENIED"
    case .deviceDisconnected: return "DEVICE_DISCONNECTED"
    case .serviceUnavailable: return "SERVICE_UNAVAILABLE"
    case .captureFailure: return "CAPTURE_FAILED"
    case .sessionSetupFailed: return "SETUP_FAILED"
    @unknown default: return "PHOTO_ERROR"
    }
  }

  // MARK: - The display and the inputs

  /// Attaches what was asked for once the device has proved it is there (the
  /// stream's first frames). Each is idempotent.
  private func attachExtrasIfNeeded() {
    guard let session else { return }
    if wantsInputs { attachInputsIfNeeded(to: session) }
    if wantsDisplay { attachDisplayIfNeeded(to: session) }
  }

  private func reviveExtras(gen: Int) {
    guard gen == generation else { return }
    if let display, display.state != .started {
      displayRestarts = 0
      restartDisplay(gen: gen)
    }
    if let inputs, inputs.state == .inactive, inputsHasActivated {
      reviveInputs(gen: gen)
    }
  }

  private func attachDisplayIfNeeded(to session: DeviceSession) {
    guard display == nil else { return }
    // A device the session cannot name yet is tried anyway: `addDisplay`
    // throws on glasses without one, and that is reported the same way.
    if let device = session.device, !device.supportsDisplay() {
      emit(["type": "display", "state": "none"])
      return
    }
    let attached: Display
    do {
      attached = try session.addDisplay()
    } catch {
      emit(["type": "error", "where": "display", "code": "DISPLAY_FAILED", "detail": String(describing: error)])
      return
    }
    display = attached
    let gen = generation
    displayTokens.append(
      attached.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.displayChanged(state, gen: gen) }
      })
    attached.start()
  }

  private func displayChanged(_ state: DisplayState, gen: Int) {
    guard gen == generation else { return }
    emit(["type": "display", "state": String(describing: state)])
    if state == .started {
      displayHasStarted = true
      displayRestarts = 0
      if let card = lastCard {
        Task { @MainActor [weak self] in await self?.draw(card, gen: gen) }
      }
    } else if state == .stopped, displayHasStarted {
      restartDisplay(gen: gen)
    }
  }

  private func restartDisplay(gen: Int) {
    guard displayRestarts < revivalAttempts else { return }
    displayRestarts += 1
    let delay = revivalDelaySeconds
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, gen == self.generation, let display = self.display,
        display.state == .stopped
      else { return }
      display.start()
    }
  }

  /// Shows the card now if the display is up, and again whenever it comes back.
  func show(_ card: CaptureCard) async throws {
    lastCard = card
    guard let display else { return }
    guard display.state == .started else { return }
    try await sendCard(card, to: display)
  }

  private func draw(_ card: CaptureCard, gen: Int) async {
    guard gen == generation, let display, display.state == .started else { return }
    do {
      try await sendCard(card, to: display)
    } catch {
      emit(["type": "error", "where": "display", "code": "SEND_FAILED", "detail": String(describing: error)])
    }
  }

  private func sendCard(_ card: CaptureCard, to display: Display) async throws {
    let gen = generation
    let view = FlexBox(direction: .column, spacing: 12) {
      Text(card.title, style: .heading)
      for line in card.lines {
        Text(line, style: .body)
      }
      if let meta = card.meta {
        Text(meta, style: .meta, color: .secondary)
      }
      if !card.actions.isEmpty {
        ButtonGroup {
          for action in card.actions {
            makeButton(action, gen: gen)
          }
        }
      }
    }
    .padding(24)
    try await display.send(view)
  }

  private func makeButton(_ action: CaptureCard.Action, gen: Int) -> Button {
    let id = action.id
    let button = Button(
      label: action.label,
      style: action.primary ? .primary : .secondary,
      iconName: action.icon.flatMap { IconName(rawValue: $0) },
      onClick: { [weak self] in
        Task { @MainActor in
          guard let self, gen == self.generation else { return }
          self.emit(["type": "tap", "id": id])
        }
      }
    )
    return action.primary ? button.actionRole(.primary) : button
  }

  private func attachInputsIfNeeded(to session: DeviceSession) {
    guard inputs == nil else { return }
    // The band is left out: it moves focus on the card. Back is consumed, so
    // a back swipe reaches the app as an event instead of ending the session.
    let configuration = InputsConfiguration(
      sources: [.captouch, .captureButton, .actionButton],
      consumeBack: true
    )
    let attached: Inputs?
    do {
      attached = try session.addInputs(configuration: configuration)
    } catch {
      emit(["type": "error", "where": "inputs", "code": "INPUTS_FAILED", "detail": String(describing: error)])
      return
    }
    guard let attached else {
      emit(["type": "inputs", "state": "none"])
      return
    }
    inputs = attached
    inputsHasActivated = false
    let gen = generation
    let stream = attached.events
    inputsDrain = Task { @MainActor [weak self] in
      for await event in stream {
        guard let self, gen == self.generation else { return }
        self.receive(event)
      }
    }
    inputsTokens.append(
      attached.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.inputsChanged(state, gen: gen) }
      })
    inputsTokens.append(
      attached.errorPublisher.listen { [weak self] error in
        let detail = error.description
        Task { @MainActor in
          guard let self, gen == self.generation else { return }
          self.emit(["type": "error", "where": "inputs", "code": "INPUTS_ERROR", "detail": detail])
        }
      })
  }

  private func inputsChanged(_ state: InputsState, gen: Int) {
    guard gen == generation else { return }
    emit(["type": "inputs", "state": state.description])
    if state == .active {
      inputsHasActivated = true
    } else if state == .inactive, inputsHasActivated {
      // A crossing takes the button away, and it does not come back by
      // itself: the dead capability is removed before a live one can attach.
      reviveInputs(gen: gen)
    }
  }

  private func reviveInputs(gen: Int) {
    guard gen == generation, let session else { return }
    inputsDrain?.cancel()
    inputsDrain = nil
    let tokens = inputsTokens
    inputsTokens = []
    inputs = nil
    inputsHasActivated = false
    try? session.removeInputs()
    let delay = revivalDelaySeconds
    Task { @MainActor [weak self] in
      for token in tokens { await token.cancel() }
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, gen == self.generation, self.wantsInputs, let session = self.session else {
        return
      }
      self.attachInputsIfNeeded(to: session)
    }
  }

  private func receive(_ event: InputEvent) {
    switch event {
    case .capture(let press, let source, _):
      emit([
        "type": "input", "kind": "capture", "press": String(describing: press),
        "source": String(describing: source),
      ])
    case .button(let button, let source, _):
      emit([
        "type": "input", "kind": "button", "button": String(describing: button),
        "source": String(describing: source),
      ])
    case .select(let source, _):
      emit(["type": "input", "kind": "select", "source": String(describing: source)])
    case .back(let source, _):
      emit(["type": "input", "kind": "back", "source": String(describing: source)])
    case .nav(let direction, let source, _):
      emit([
        "type": "input", "kind": "nav", "direction": String(describing: direction),
        "source": String(describing: source),
      ])
    case .drag:
      break
    @unknown default:
      break
    }
  }

  private func emit(_ event: [String: Any]) {
    events.send(event)
  }
}

// MARK: - The method channel

extension MetaWearablesDatPlugin {
  /// `captureStart({display, inputs})`: answers the session's status once a
  /// still can be taken.
  func captureStart(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let display = (args?["display"] as? Bool) ?? true
    let inputs = (args?["inputs"] as? Bool) ?? true
    Task { @MainActor in
      do {
        let status = try await self.captureController().start(display: display, inputs: inputs)
        result(status)
      } catch let failure as CaptureFailure {
        result(FlutterError(code: failure.code, message: failure.detail, details: nil))
      } catch {
        result(FlutterError(code: "CAPTURE_ERROR", message: String(describing: error), details: nil))
      }
    }
  }

  /// `captureStill({resolution, quality})`: answers the photo's bytes.
  func captureStill(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let resolution = PhotoResolution(rawValue: (args?["resolution"] as? String) ?? "") ?? .medium
    let quality = PhotoQuality(rawValue: (args?["quality"] as? String) ?? "") ?? .high
    Task { @MainActor in
      do {
        let bytes = try await self.captureController().still(resolution: resolution, quality: quality)
        result(FlutterStandardTypedData(bytes: bytes))
      } catch let failure as CaptureFailure {
        result(FlutterError(code: failure.code, message: failure.detail, details: nil))
      } catch {
        result(FlutterError(code: "CAPTURE_ERROR", message: String(describing: error), details: nil))
      }
    }
  }

  /// `captureShow({title, lines, meta, buttons})`: draws the card on the
  /// display (now, and again whenever the display comes back).
  func captureShow(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any], let card = CaptureCard(args) else {
      result(FlutterError(code: "BAD_CARD", message: "a card needs a title", details: nil))
      return
    }
    Task { @MainActor in
      do {
        try await self.captureController().show(card)
        result(true)
      } catch {
        result(FlutterError(code: "SEND_FAILED", message: String(describing: error), details: nil))
      }
    }
  }

  /// `captureStop({endSession})`: puts the capture session down.
  func captureStop(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let ending = (args?["endSession"] as? Bool) ?? true
    Task { @MainActor in
      await self.captureController().stop(endingSession: ending)
      result(true)
    }
  }
}
