// CONCETTO FORK (simulated glasses): what the Dart side sends down the method
// channel for Meta's Mock Device Kit, and what a platform without it answers.

import 'package:flutter/services.dart';
import 'package:flutter_meta_wearables_dat/meta_wearables_dat_method_channel.dart';
import 'package:flutter_meta_wearables_dat/meta_wearables_dat_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bare extends MetaWearablesDatPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_meta_wearables_dat');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final platform = MethodChannelMetaWearablesDat();
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'simulatedStart' => 'mock-display-1',
        'simulatedVoiceLaunch' => 'launched',
        _ => true,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('start sends the model and answers the simulated pair', () async {
    expect(await platform.simulatedStart(), 'mock-display-1');
    expect(await platform.simulatedStart(model: 'camera'), 'mock-display-1');
    expect(calls.map((c) => c.arguments), [
      {'model': 'display'},
      {'model': 'camera'},
    ]);
  });

  test('a press sends its kind', () async {
    expect(await platform.simulatedPress('capture'), isTrue);
    expect(calls.single.method, 'simulatedPress');
    expect(calls.single.arguments, {'kind': 'capture'});
  });

  test('the rest carry no arguments', () async {
    expect(await platform.simulatedAvailable(), isTrue);
    expect(await platform.simulatedFailNextPhoto(), isTrue);
    expect(await platform.simulatedVoiceLaunch(), 'launched');
    expect(await platform.simulatedStop(), isTrue);
    expect(calls.map((c) => c.method), [
      'simulatedAvailable',
      'simulatedFailNextPhoto',
      'simulatedVoiceLaunch',
      'simulatedStop',
    ]);
    expect(calls.every((c) => c.arguments == null), isTrue);
  });

  test('a platform without simulated glasses says so', () async {
    final bare = _Bare();
    expect(await bare.simulatedAvailable(), isFalse);
    expect(await bare.simulatedPress('capture'), isFalse);
    expect(await bare.simulatedVoiceLaunch(), isNull);
  });
}
