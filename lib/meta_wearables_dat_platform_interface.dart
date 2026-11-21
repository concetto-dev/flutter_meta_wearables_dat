// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_meta_wearables_dat/flutter_meta_wearables_dat.dart';
import 'package:flutter_meta_wearables_dat/meta_wearables_dat_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

abstract class MetaWearablesDatPlatform extends PlatformInterface {
  /// Constructs a MetaWearablesDatPlatform.
  MetaWearablesDatPlatform() : super(token: _token);

  static final Object _token = Object();

  static MetaWearablesDatPlatform _instance = MethodChannelMetaWearablesDat();

  /// The default instance of [MetaWearablesDatPlatform] to use.
  ///
  /// Defaults to [MethodChannelMetaWearablesDat].
  static MetaWearablesDatPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MetaWearablesDatPlatform] when
  /// they register themselves.
  static set instance(MetaWearablesDatPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// CONCETTO FORK: starts Meta's kit. See [MetaWearablesDat.configure].
  Future<bool> configure() {
    throw UnimplementedError('configure() has not been implemented.');
  }

  Future<bool> requestAndroidPermissions() {
    throw UnimplementedError(
      'requestAndroidPermissions() has not been implemented.',
    );
  }

  Future<bool> requestCameraPermission() {
    throw UnimplementedError(
      'requestCameraPermission() has not been implemented.',
    );
  }

  Future<bool> getCameraPermissionStatus() {
    throw UnimplementedError(
      'getCameraPermissionStatus() has not been implemented.',
    );
  }

  Future<bool> requestMicrophonePermission() {
    throw UnimplementedError(
      'requestMicrophonePermission() has not been implemented.',
    );
  }

  Future<bool> getMicrophonePermissionStatus() {
    throw UnimplementedError(
      'getMicrophonePermissionStatus() has not been implemented.',
    );
  }

  /// 16-bit PCM mono audio from the glasses' microphones, while a stream
  /// started with `audio: true` is running.
  Stream<Uint8List> audioFramesStream() {
    throw UnimplementedError('audioFramesStream() has not been implemented.');
  }

  Future<bool> startRegistration() {
    throw UnimplementedError('startRegistration() has not been implemented.');
  }

  Future<bool> handleUrl(String url) {
    throw UnimplementedError('handleUrl() has not been implemented.');
  }

  Future<bool> disconnect() {
    throw UnimplementedError('disconnect() has not been implemented.');
  }

  /// Starts a stream session. Returns a texture ID (int) for rendering
  /// via the Flutter `Texture` widget (zero-copy path).
  Future<int> startStreamSession(
    String? deviceId, {
    StreamFrameRate frameRate = StreamFrameRate.fps30,
    StreamQuality streamQuality = StreamQuality.high,
    VideoCodec videoCodec = VideoCodec.raw,
    bool audio = false,
  }) {
    throw UnimplementedError('startStreamSession() has not been implemented.');
  }

  Future<bool> stopStreamSession(String? deviceId) {
    throw UnimplementedError('stopStreamSession() has not been implemented.');
  }

  Future<CapturedPhoto> capturePhoto(
    String? deviceId, {
    PhotoCaptureFormat format = PhotoCaptureFormat.jpeg,
  }) {
    throw UnimplementedError('capturePhoto() has not been implemented.');
  }

  Future<RegistrationState> getRegistrationState() {
    throw UnimplementedError(
      'getRegistrationState() has not been implemented.',
    );
  }

  Stream<RegistrationState> registrationStateStream() {
    throw UnimplementedError(
      'registrationStateStream() has not been implemented.',
    );
  }

  Stream<StreamSessionState> streamSessionStateStream() {
    throw UnimplementedError(
      'streamSessionStateStream() has not been implemented.',
    );
  }

  Stream<StreamSessionError> streamSessionErrorStream() {
    throw UnimplementedError(
      'streamSessionErrorStream() has not been implemented.',
    );
  }

  Stream<bool> activeDeviceStream() {
    throw UnimplementedError('activeDeviceStream() has not been implemented.');
  }

  Future<List<WearableDevice>> getDevices() {
    throw UnimplementedError('getDevices() has not been implemented.');
  }

  Stream<VideoStreamSize> videoStreamSizeStream() {
    throw UnimplementedError(
      'videoStreamSizeStream() has not been implemented.',
    );
  }

  Future<bool> restartActiveDeviceMonitoring() {
    throw UnimplementedError(
      'restartActiveDeviceMonitoring() has not been implemented.',
    );
  }

  Future<void> enableBackgroundStreaming({
    BackgroundNotification? androidNotification,
  }) {
    throw UnimplementedError(
      'enableBackgroundStreaming() has not been implemented.',
    );
  }

  Future<void> disableBackgroundStreaming() {
    throw UnimplementedError(
      'disableBackgroundStreaming() has not been implemented.',
    );
  }

  Future<bool> isBackgroundStreamingEnabled() {
    throw UnimplementedError(
      'isBackgroundStreamingEnabled() has not been implemented.',
    );
  }

  Stream<VideoFrame> videoFramesStream({double? maxFramesPerSecond}) {
    throw UnimplementedError('videoFramesStream() has not been implemented.');
  }

  Future<bool> openDATGlassesAppUpdate() {
    throw UnimplementedError(
      'openDATGlassesAppUpdate() has not been implemented.',
    );
  }

  Stream<DeviceState> deviceStateStream() {
    throw UnimplementedError('deviceStateStream() has not been implemented.');
  }

  // CONCETTO FORK (capture session): see MetaWearablesDat.captureStart.

  Future<Map<String, Object?>> captureStart({
    required bool display,
    required bool inputs,
  }) {
    throw UnimplementedError('captureStart() has not been implemented.');
  }

  Future<Uint8List> captureStill({
    required String resolution,
    required String quality,
  }) {
    throw UnimplementedError('captureStill() has not been implemented.');
  }

  Future<bool> captureShow(Map<String, Object?> card) {
    throw UnimplementedError('captureShow() has not been implemented.');
  }

  Future<bool> captureStop({required bool endSession}) {
    throw UnimplementedError('captureStop() has not been implemented.');
  }

  Stream<Map<String, Object?>> captureEvents() {
    throw UnimplementedError('captureEvents() has not been implemented.');
  }

  // CONCETTO FORK (voice on camera glasses, choosing the pair).

  Future<bool> voiceListen() {
    throw UnimplementedError('voiceListen() has not been implemented.');
  }

  Future<bool> speechStart() {
    throw UnimplementedError('speechStart() has not been implemented.');
  }

  Future<bool> speechStop() {
    throw UnimplementedError('speechStop() has not been implemented.');
  }

  Future<bool> speak(String text, {String? language}) {
    throw UnimplementedError('speak() has not been implemented.');
  }

  Future<bool> speakStop() {
    throw UnimplementedError('speakStop() has not been implemented.');
  }

  Stream<Map<String, Object?>> voiceEvents() {
    throw UnimplementedError('voiceEvents() has not been implemented.');
  }

  Future<bool> setDevice(String? deviceId) {
    throw UnimplementedError('setDevice() has not been implemented.');
  }

  Future<bool> simulatedAvailable() async => false;

  Future<String?> simulatedStart({String model = 'display'}) {
    throw UnimplementedError('simulatedStart() has not been implemented.');
  }

  Future<bool> simulatedPress(String kind) async => false;

  Future<bool> simulatedFailNextPhoto() async => false;

  Future<String?> simulatedVoiceLaunch() async => null;

  Future<bool> simulatedStop() async => false;
}
