// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice that speaks a `/tts` line (decision 0142) stands for the member who typed it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

VoiceParticipant _who(String identity) => VoiceParticipant(
      identity: identity,
      name: 'Nick',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
    );

void main() {
  test('a /tts voice is that member, and a person is themselves', () {
    final voice = _who('tts-user-7');
    expect((voice.isSpeechSynth, voice.userId), (true, 'user-7'));
    final person = _who('user-7');
    expect((person.isSpeechSynth, person.userId), (false, 'user-7'));
  });
}
