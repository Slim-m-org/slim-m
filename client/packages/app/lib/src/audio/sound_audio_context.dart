// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The audio session a chime asks `audioplayers` for. audioplayers calls
/// `setCategory` on iOS for every play, and during a call the WebRTC session
/// already holds play-and-record, so switching it to ambient is refused with
/// "!pri" (insufficient priority). In a call the sound asks for that same
/// category, mixing with the call, instead of a different one.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show isIOSHost;

const _androidSoundContext = AudioContextAndroid(
  contentType: AndroidContentType.sonification,
  usageType: AndroidUsageType.notificationEvent,
  audioFocus: AndroidAudioFocus.none,
);

/// [ios] and [inCall] are parameters so a test can pick either side; Android
/// and desktop get the same context whatever they are.
AudioContext soundAudioContext({bool? ios, bool inCall = false}) {
  final onIOS = ios ?? isIOSHost;
  if (!onIOS || !inCall) {
    return AudioContext(
      iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
      android: _androidSoundContext,
    );
  }
  return AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: const {
        AVAudioSessionOptions.mixWithOthers,
        AVAudioSessionOptions.defaultToSpeaker,
        AVAudioSessionOptions.allowBluetooth,
        AVAudioSessionOptions.allowBluetoothA2DP,
      },
    ),
    android: _androidSoundContext,
  );
}

/// Runs [play], logging an audio session refusal at debug level: a chime that
/// cannot play is not worth an error.
Future<void> playQuietly(Future<void> Function() play) async {
  try {
    await play();
  } on TimeoutException {
    rethrow;
  } on Object catch (error, stack) {
    if (!_isSessionRefusal(error)) rethrow;
    AppLog.swallowed(LogTag.platform, 'A sound could not play', error, stack);
  }
}

bool _isSessionRefusal(Object error) =>
    error.toString().contains('DarwinAudioError');
