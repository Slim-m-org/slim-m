// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iOS session a chime asks for: ambient when idle, the call's own
/// play-and-record category, mixing, while a call holds the session.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/audio/sound_audio_context.dart';

void main() {
  test('idle on iOS stays ambient', () {
    final ios = soundAudioContext(ios: true).iOS;
    expect(ios.category, AVAudioSessionCategory.ambient);
  });

  test('in a call on iOS it joins play-and-record and mixes', () {
    final ios = soundAudioContext(ios: true, inCall: true).iOS;
    expect(ios.category, AVAudioSessionCategory.playAndRecord);
    expect(ios.options, contains(AVAudioSessionOptions.mixWithOthers));
    expect(ios.options, contains(AVAudioSessionOptions.defaultToSpeaker));
    expect(ios.options, contains(AVAudioSessionOptions.allowBluetooth));
  });

  test('Android and desktop get the same context in a call or not', () {
    final idle = soundAudioContext(ios: false);
    final call = soundAudioContext(ios: false, inCall: true);
    expect(call, idle);
    expect(idle.android.audioFocus, AndroidAudioFocus.none);
    expect(AudioPlayersSoundPlayer.sharedAmbientContext, idle);
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
