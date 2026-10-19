// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sends the interface sounds to the speaker the call uses.
///
/// `audioplayers` has no output device option, so on Linux the player's own
/// stream is moved on the sound server, the way the call's audio already is.
/// Windows, macOS, iOS, Android and the browser play these on the system default.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/providers/voice_controller.dart';

/// A player's stream appears a moment after `play`, so the move is retried.
const List<Duration> soundRouteDelays = [
  Duration.zero,
  Duration(milliseconds: 40),
  Duration(milliseconds: 120),
  Duration(milliseconds: 300),
];

class SoundOutputRouter {
  SoundOutputRouter(
    this._chosenOutput, {
    PulseAudio? pulse,
    bool? supported,
    List<Duration> delays = soundRouteDelays,
  }) : _pulse = pulse ?? PulseAudio(),
       supported = supported ?? PulseAudio.supported,
       _delays = delays;

  final String? Function() _chosenOutput;
  final PulseAudio _pulse;
  final List<Duration> _delays;

  /// Whether a chosen speaker reaches the interface sounds on this platform.
  final bool supported;

  /// Whether a Test speaker button would play where the person chose.
  bool get testable => supported || _chosenOutput() == null;

  /// Moves the app's playing streams to the chosen speaker.
  Future<void> followChosenOutput() async {
    final output = _chosenOutput();
    if (!supported || !isPulseDeviceId(output)) return;
    for (final delay in _delays) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        await _pulse.moveOwnStreams(capture: false, deviceId: output!);
      } on Object catch (error, stack) {
        AppLog.swallowed(
          LogTag.voice,
          'Could not move an interface sound to the chosen speaker',
          error,
          stack,
        );
        return;
      }
    }
  }
}

final soundOutputRouterProvider = Provider<SoundOutputRouter>((ref) {
  final voice = ref.read(voiceControllerProvider.notifier);
  return SoundOutputRouter(() => voice.audioOutputInUse);
});
