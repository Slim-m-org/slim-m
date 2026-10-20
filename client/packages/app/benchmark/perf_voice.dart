// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call whose roster a benchmark can change at will, with no media session.
library;

import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../test/features/voice/fake_voice_session.dart';

class PerfVoice extends VoiceController {
  PerfVoice(super.ref, VoiceState initial) : super(session: FakeSession()) {
    state = initial;
  }

  void set(VoiceState next) => state = next;
}

List<VoiceParticipant> roster(int count, {Set<int> speaking = const {}}) => [
  for (var i = 0; i < count; i++)
    VoiceParticipant(
      identity: i == 0 ? 'me' : 'user-$i',
      name: 'Participant $i',
      isSpeaking: speaking.contains(i),
      isMuted: i.isOdd,
      isLocal: i == 0,
      isScreenSharing: false,
    ),
];

VoiceState callOf(int participants, {Set<int> speaking = const {}}) =>
    participants == 0
    ? const VoiceState()
    : VoiceState(
        channelId: 'c1',
        state: VoiceSessionState.connected,
        participants: roster(participants, speaking: speaking),
      );
