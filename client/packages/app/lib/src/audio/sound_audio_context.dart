// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a chime may play while a call holds the device's audio.
///
/// On iOS audioplayers sets the shared session's category on every play and
/// deactivates the session when its last player stops. During a call that
/// session is WebRTC's, so a chime there could switch the mic off, move the
/// call to the speaker, or stop its audio; it is skipped instead.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show isIOSHost;

/// The context every sound plays under: ambient on iOS, no focus on Android.
final soundAudioContext = AudioContext(
  iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
  android: const AudioContextAndroid(
    contentType: AndroidContentType.sonification,
    usageType: AndroidUsageType.notificationEvent,
    audioFocus: AndroidAudioFocus.none,
  ),
);

/// Whether a sound must stay silent so the call keeps its iOS audio session.
bool callOwnsSoundSession({required bool inCall, bool? ios}) =>
    inCall && (ios ?? isIOSHost);

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
