// CONCETTO FORK (capture session): the Dart half of the photo, display and
// inputs session. The Swift half (CaptureSessionController.swift) is proven
// only on a Mac build and the glasses.

import 'package:flutter/services.dart';
import 'package:flutter_meta_wearables_dat/flutter_meta_wearables_dat.dart';
import 'package:flutter_meta_wearables_dat/meta_wearables_dat_method_channel.dart';
import 'package:flutter_meta_wearables_dat/meta_wearables_dat_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_meta_wearables_dat');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    MetaWearablesDatPlatform.instance = MethodChannelMetaWearablesDat();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('captureStart sends what the session carries and answers its status',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return <Object?, Object?>{
        'ready': true,
        'display': true,
        'inputs': false,
        'supportsDisplay': true,
      };
    });
    final status = await MetaWearablesDat.captureStart(inputs: false);
    expect(calls.single.method, 'captureStart');
    expect(calls.single.arguments, {'display': true, 'inputs': false});
    expect(status['ready'], true);
    expect(status['supportsDisplay'], true);
  });

  test('captureStill answers the bytes and defaults to 720p at high quality',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return Uint8List.fromList([1, 2, 3]);
    });
    final bytes = await MetaWearablesDat.captureStill();
    expect(bytes, [1, 2, 3]);
    expect(calls.single.arguments, {'resolution': 'medium', 'quality': 'high'});
  });

  test('captureStill passes the SDK reason through as the exception code',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'PHOTO_BUSY', message: 'crossing');
    });
    await expectLater(
      MetaWearablesDat.captureStill(),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'PHOTO_BUSY')),
    );
  });

  test('captureShow sends the card as it is', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final card = <String, Object?>{
      'title': 'Test property',
      'lines': ['3 photos saved'],
      'buttons': [
        {'id': 'photo', 'label': 'Take photo', 'icon': 'mountainSquare', 'primary': true},
      ],
    };
    expect(await MetaWearablesDat.captureShow(card), true);
    expect(calls.single.method, 'captureShow');
    expect(calls.single.arguments, card);
  });

  test('captureStop ends the session by default', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    await MetaWearablesDat.captureStop();
    expect(calls.single.arguments, {'endSession': true});
  });

  test('captureEvents decodes each event as a map', () async {
    const events = 'flutter_meta_wearables_dat/capture_events';
    messenger.setMockStreamHandler(
      const EventChannel(events),
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success(<Object?, Object?>{'type': 'tap', 'id': 'photo'});
          sink.endOfStream();
        },
      ),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(const EventChannel(events), null),
    );
    final got = await MetaWearablesDat.captureEvents().toList();
    expect(got, [
      {'type': 'tap', 'id': 'photo'},
    ]);
  });
}
