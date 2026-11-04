// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sound never touches the iOS audio session while a call holds it.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/audio/sound_audio_context.dart';

void main() {
  test('only an iOS call keeps sounds silent', () {
    expect(callOwnsSoundSession(inCall: true, ios: true), isTrue);
    expect(callOwnsSoundSession(inCall: false, ios: true), isFalse);
    expect(callOwnsSoundSession(inCall: true, ios: false), isFalse);
    expect(callOwnsSoundSession(inCall: false, ios: false), isFalse);
  });

  test('every sound plays ambient on iOS and without focus on Android', () {
    expect(soundAudioContext.iOS.category, AVAudioSessionCategory.ambient);
    expect(soundAudioContext.android.audioFocus, AndroidAudioFocus.none);
    expect(AudioPlayersSoundPlayer.sharedAmbientContext, soundAudioContext);
  });

  test('a chime during an iOS call never reaches the audio plugin', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
      );
    }
    final player = AudioPlayersSoundPlayer(inCall: () => true, ios: true);

    await player.play(NotificationSound.selfJoin);
    await player.loop(NotificationSound.selfJoin);

    expect(calls, isEmpty, reason: 'no setAudioContext or play may be sent');
  });

  test('a refused audio session is swallowed, anything else is not', () async {
    await playQuietly(
      () async => throw PlatformException(
        code: 'DarwinAudioError',
        message: 'Error configuring audio session: 561017449 "!pri"',
      ),
    );
    await expectLater(
      playQuietly(() async => throw StateError('real bug')),
      throwsStateError,
    );
  });
}
