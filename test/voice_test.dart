// CONCETTO FORK (voice on camera glasses, choosing the pair): what the Dart
// side sends down the method channel.

import 'package:flutter/services.dart';
import 'package:flutter_meta_wearables_dat/meta_wearables_dat_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

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
      return true;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('speak sends the text, and the language only when given', () async {
    expect(await platform.speak('Two visits today.'), isTrue);
    expect(await platform.speak('Dos visitas hoy.', language: 'es-US'), isTrue);
    expect(calls.map((c) => c.method), ['speak', 'speak']);
    expect(calls.first.arguments, {'text': 'Two visits today.'});
    expect(calls.last.arguments, {'text': 'Dos visitas hoy.', 'language': 'es-US'});
  });

  test('setDevice pins a pair and null goes back to auto-select', () async {
    await platform.setDevice('pair-1');
    await platform.setDevice(null);
    expect(calls.map((c) => c.method), ['setDevice', 'setDevice']);
    expect(calls.first.arguments, {'deviceId': 'pair-1'});
    expect(calls.last.arguments, {'deviceId': null});
  });

  test('the voice calls carry no arguments', () async {
    await platform.voiceListen();
    await platform.speechStart();
    await platform.speechStop();
    await platform.speakStop();
    expect(calls.map((c) => c.method), ['voiceListen', 'speechStart', 'speechStop', 'speakStop']);
    expect(calls.every((c) => c.arguments == null), isTrue);
  });

  test('a channel that answers nothing reads as false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await platform.speak('x'), isFalse);
    expect(await platform.setDevice('pair-1'), isFalse);
  });
}
