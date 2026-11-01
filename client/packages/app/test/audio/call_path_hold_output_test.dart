// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// iPhone hold music goes to the app's own engine, never to a plugin that
/// resets the call's audio session.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_path_hold_output.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var seconds = 12.0;

  setUp(() {
    calls.clear();
    seconds = 12.0;
    messenger.setMockMethodCallHandler(
      const MethodChannel(holdMusicChannelName),
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'assetPath' => '/bundle/lofi.mp3',
          'play' => 180.0,
          'position' => seconds,
          _ => null,
        };
      },
    );
  });

  tearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel(holdMusicChannelName),
      null,
    ),
  );

  test(
    'play hands the native side a bundle path and reports the length',
    () async {
      final output = CallPathHoldOutput();
      await output.play('audio/music/lofi.mp3');

      final assetCall = calls.firstWhere((c) => c.method == 'assetPath');
      expect(assetCall.arguments, {'asset': 'assets/audio/music/lofi.mp3'});
      final play = calls.firstWhere((c) => c.method == 'play');
      expect((play.arguments as Map)['path'], '/bundle/lofi.mp3');
      expect(output.playback.value.duration, const Duration(minutes: 3));
      await output.stop();
    },
  );

  test('the timeline follows the engine and resets on stop', () async {
    final output = CallPathHoldOutput();
    await output.play('audio/music/lofi.mp3');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(output.playback.value.position, const Duration(seconds: 12));

    await output.stop();
    expect(output.playback.value, HoldPlayback.idle);
    expect(calls.last.method, 'stop');
  });

  test('pause stops asking for the position until resume', () async {
    final output = CallPathHoldOutput();
    await output.play('audio/music/lofi.mp3');
    await output.pause();
    calls.clear();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(calls.where((c) => c.method == 'position'), isEmpty);

    await output.resume();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(calls.where((c) => c.method == 'position'), isNotEmpty);
    await output.stop();
  });

  test('a native refusal is swallowed so the call carries on', () async {
    messenger.setMockMethodCallHandler(
      const MethodChannel(holdMusicChannelName),
      (call) async => call.method == 'play'
          ? throw PlatformException(code: 'play_failed')
          : '/x',
    );
    final output = CallPathHoldOutput();
    await output.play('audio/music/lofi.mp3');
    expect(output.playback.value.duration, isNull);
    await output.stop();
  });

  test('hold music is offered on every platform', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(holdMusicAvailableProvider), isTrue);
  });
}
