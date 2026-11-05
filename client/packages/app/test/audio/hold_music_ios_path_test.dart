// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On iPhone hold music plays on the call's own engine, never through audioplayers.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/call_path_hold_output.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an iOS hold music start only talks to the call-path channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pluginCalls = <String>[];
    final holdCalls = <String>[];
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        pluginCalls.add(call.method);
        return null;
      });
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel(holdMusicChannelName),
      (call) async {
        holdCalls.add(call.method);
        return switch (call.method) {
          'assetPath' => '/bundle/lofi.mp3',
          'play' => 30.0,
          _ => null,
        };
      },
    );
    addTearDown(() {
      for (final name in [
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
        holdMusicChannelName,
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
    });

    final player = AudioPlayersHoldMusicPlayer(ios: true);
    await player.start();
    await player.stop();
    await player.dispose();

    expect(holdCalls, containsAll(['assetPath', 'play']));
    expect(pluginCalls, isEmpty);
  });
}
