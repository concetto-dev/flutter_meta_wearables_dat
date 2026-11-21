// CONCETTO FORK (simulated glasses, 2026-11-21): Meta's Mock Device Kit
// (MWDATMockDevice 1.0.1) as a pair of glasses in a debug build, on the iOS
// Simulator or a developer's phone. Meta's display simulation guide:
// https://wearables.developer.meta.com/docs/develop/dat/display-simulation
//
// Nothing here links MWDATMockDevice. The kit is found at run time through
// its Objective-C names (MWDATMockDeviceKit and the selectors in its
// MWDATMockDevice-Swift.h), and loaded with dlopen from the app's Frameworks
// folder. Only a debug build embeds it there (MockDevice/embed-mock-device.sh,
// a Debug-only build phase), so a TestFlight or production build carries no
// trace of it, and the whole body is compiled for DEBUG only besides.
//
// What it gives the app: simulated glasses that pair, power on and are worn;
// the 600 x 600 display drawn in a floating view over the app; the frame's
// capture button, the arrows, select and back; a photo to return from the
// camera, or a capture that fails; and a "Hey Meta, start ..." launch.

import Foundation
import UIKit

#if DEBUG

// The kit's Objective-C surface, as declared in MWDATMockDevice-Swift.h. A
// call through these goes by selector (objc_msgSend), so the classes need
// not formally conform.
@objc fileprivate protocol MockKitObjC {
  var isEnabled: Bool { get }
  func enable(initiallyRegistered: Bool)
  func disable()
  func pairGlasses(modelRawValue: String) -> AnyObject?
  func unpairDevice(_ device: AnyObject)
}

@objc fileprivate protocol MockGlassesObjC {
  var deviceIdentifier: String { get }
  func powerOn()
  func powerOff()
  func don()
  func doff()
  func fold()
  func unfold()
  var services: AnyObject { get }
}

@objc fileprivate protocol MockServicesObjC {
  var input: AnyObject { get }
  var display: AnyObject { get }
  var cameraCapture: AnyObject { get }
  var voiceInvocation: AnyObject { get }
}

@objc fileprivate protocol MockInputObjC {
  func navUp(source: Int)
  func navDown(source: Int)
  func navLeft(source: Int)
  func navRight(source: Int)
  func select(source: Int)
  func back(source: Int)
  func capture(pressType: Int)
}

@objc fileprivate protocol MockDisplayObjC {
  func createPreviewView() -> UIView
}

@objc fileprivate protocol MockCameraCaptureObjC {
  func setCapturedPhoto(fileURL: URL)
  func simulateCaptureFailure()
}

@objc fileprivate protocol MockVoiceInvocationObjC {
  func sendLaunchAppAction() -> String?
}

/// MWDATInputSource and MWDATCapturePressType, as their NSInteger values.
private enum MockSource {
  static let captouch = 0
  static let neuralBand = 1
}

private enum MockPress {
  static let shortPress = 0
  static let hold = 1
  static let doublePress = 2
}

#endif

@MainActor
final class SimulatedGlasses {
  struct Failure: Error {
    let code: String
    let detail: String
  }

  #if DEBUG
  private var glasses: AnyObject?
  private var preview: UIView?
  #endif

  /// True when this build can simulate glasses: a debug build that embeds
  /// MWDATMockDevice.
  var isAvailable: Bool {
    #if DEBUG
    return Self.kit() != nil
    #else
    return false
    #endif
  }

  /// Pairs, powers on and wears simulated glasses of [model] ("display" for
  /// Meta Ray-Ban Display, anything else for Ray-Ban Meta), shows the
  /// display over the app for the Display, and answers their identifier.
  func start(model: String) throws -> String {
    #if DEBUG
    guard let kitObject = Self.kit() else {
      throw Failure(code: "NOT_AVAILABLE", detail: "this build does not embed MWDATMockDevice")
    }
    let kit = unsafeBitCast(kitObject, to: MockKitObjC.self)
    if glasses != nil { stop() }
    if !kit.isEnabled { kit.enable(initiallyRegistered: true) }
    // GlassesModel's raw values are display names; the header's example is
    // "Ray-Ban Meta". The kit answers nil for a name it does not know.
    let names = model == "display"
      ? ["Meta Ray-Ban Display", "Ray-Ban Display"]
      : ["Ray-Ban Meta"]
    var paired: AnyObject?
    for name in names {
      paired = kit.pairGlasses(modelRawValue: name)
      if paired != nil { break }
    }
    guard let pairedObject = paired else {
      throw Failure(code: "PAIR_FAILED", detail: "no model named \(names)")
    }
    glasses = pairedObject
    let worn = unsafeBitCast(pairedObject, to: MockGlassesObjC.self)
    worn.powerOn()
    worn.unfold()
    worn.don()
    if let photo = Self.samplePhoto() {
      cameraCapture()?.setCapturedPhoto(fileURL: photo)
    }
    if model == "display" { showPreview() }
    return worn.deviceIdentifier
    #else
    throw Failure(code: "NOT_AVAILABLE", detail: "release build")
    #endif
  }

  /// A press on the simulated glasses: capture, capture_hold, up, down,
  /// left, right, select, back. False when none are paired.
  func press(_ kind: String) -> Bool {
    #if DEBUG
    guard let input = input() else { return false }
    switch kind {
    case "capture": input.capture(pressType: MockPress.shortPress)
    case "capture_hold": input.capture(pressType: MockPress.hold)
    case "capture_double": input.capture(pressType: MockPress.doublePress)
    case "up": input.navUp(source: MockSource.neuralBand)
    case "down": input.navDown(source: MockSource.neuralBand)
    case "left": input.navLeft(source: MockSource.neuralBand)
    case "right": input.navRight(source: MockSource.neuralBand)
    case "select": input.select(source: MockSource.neuralBand)
    case "back": input.back(source: MockSource.captouch)
    default: return false
    }
    return true
    #else
    return false
    #endif
  }

  /// The next photo the glasses are asked for fails, as a real one can.
  func failNextPhoto() -> Bool {
    #if DEBUG
    guard let capture = cameraCapture() else { return false }
    capture.simulateCaptureFailure()
    return true
    #else
    return false
    #endif
  }

  /// "Hey Meta, start <app>": the launch the voice channel listens for.
  /// Answers the kit's note, or nil.
  func voiceLaunch() -> String? {
    #if DEBUG
    guard let services = services() else { return nil }
    let voice = unsafeBitCast(services.voiceInvocation, to: MockVoiceInvocationObjC.self)
    return voice.sendLaunchAppAction()
    #else
    return nil
    #endif
  }

  /// Takes the simulated glasses off, unpairs them and hides the display.
  func stop() {
    #if DEBUG
    preview?.removeFromSuperview()
    preview = nil
    if let pairedObject = glasses, let kitObject = Self.kit() {
      let worn = unsafeBitCast(pairedObject, to: MockGlassesObjC.self)
      worn.doff()
      worn.powerOff()
      unsafeBitCast(kitObject, to: MockKitObjC.self).unpairDevice(pairedObject)
    }
    glasses = nil
    #endif
  }

  #if DEBUG

  private static var loadTried = false

  /// The kit's shared instance, loading the framework the first time.
  private static func kit() -> AnyObject? {
    if NSClassFromString("MWDATMockDeviceKit") == nil, !loadTried {
      loadTried = true
      if let dir = Bundle.main.privateFrameworksPath {
        _ = dlopen(dir + "/MWDATMockDevice.framework/MWDATMockDevice", RTLD_NOW)
      }
    }
    guard let cls = NSClassFromString("MWDATMockDeviceKit") as AnyObject? else { return nil }
    return cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue()
  }

  private func services() -> MockServicesObjC? {
    guard let pairedObject = glasses else { return nil }
    let worn = unsafeBitCast(pairedObject, to: MockGlassesObjC.self)
    return unsafeBitCast(worn.services, to: MockServicesObjC.self)
  }

  private func input() -> MockInputObjC? {
    guard let services = services() else { return nil }
    return unsafeBitCast(services.input, to: MockInputObjC.self)
  }

  private func cameraCapture() -> MockCameraCaptureObjC? {
    guard let services = services() else { return nil }
    return unsafeBitCast(services.cameraCapture, to: MockCameraCaptureObjC.self)
  }

  /// The glasses' 600 x 600 display, in a 240 pt square over the app's top
  /// right corner. It can be dragged. The view is transparent where the
  /// glasses would be, so it sits on black, as the lens looks.
  private func showPreview() {
    guard let services = services(),
          let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return }
    let display = unsafeBitCast(services.display, to: MockDisplayObjC.self)
    let side: CGFloat = 240
    let frame = UIView(frame: CGRect(
      x: window.bounds.width - side - 12,
      y: window.safeAreaInsets.top + 12,
      width: side, height: side))
    frame.backgroundColor = .black
    frame.layer.cornerRadius = 12
    frame.layer.borderWidth = 1
    frame.layer.borderColor = UIColor.systemGray.cgColor
    frame.clipsToBounds = true
    frame.accessibilityIdentifier = "simulated-glasses-display"
    let lens = display.createPreviewView()
    lens.frame = frame.bounds
    lens.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    frame.addSubview(lens)
    frame.addGestureRecognizer(UIPanGestureRecognizer(
      target: PreviewDrag.shared, action: #selector(PreviewDrag.drag(_:))))
    window.addSubview(frame)
    preview = frame
  }

  /// A photo for the simulated camera to return: a plain card with the
  /// time, so each one can be told apart in the observation.
  private static func samplePhoto() -> URL? {
    let size = CGSize(width: 1280, height: 960)
    let image = UIGraphicsImageRenderer(size: size).image { ctx in
      UIColor(red: 0.25, green: 0.42, blue: 0.27, alpha: 1).setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      let stamp = ISO8601DateFormatter().string(from: Date())
      let text = "Simulated glasses photo\n\(stamp)" as NSString
      text.draw(
        in: CGRect(x: 80, y: 380, width: size.width - 160, height: 240),
        withAttributes: [
          .font: UIFont.systemFont(ofSize: 64, weight: .semibold),
          .foregroundColor: UIColor(red: 0.85, green: 0.42, blue: 0.2, alpha: 1),
        ])
    }
    guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("simulated-glasses-photo.jpg")
    do {
      try jpeg.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  #endif
}

#if DEBUG
/// Moves the floating display with a finger.
private final class PreviewDrag: NSObject {
  static let shared = PreviewDrag()

  @objc func drag(_ pan: UIPanGestureRecognizer) {
    guard let view = pan.view, let parent = view.superview else { return }
    let moved = pan.translation(in: parent)
    view.center = CGPoint(x: view.center.x + moved.x, y: view.center.y + moved.y)
    pan.setTranslation(.zero, in: parent)
  }
}
#endif
