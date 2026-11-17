// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's joins and leaves reach the session, for this call only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_server_presence.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state_access.dart';

import '../../support/dead_voice_session.dart';

class _RecordingSession extends DeadVoiceSession {
  final calls = <String>[];

  @override
  void participantLeftByServer(String identity) => calls.add('left $identity');

  @override
  void participantJoinedByServer(String identity) =>
      calls.add('joined $identity');
}

void main() {
  late _RecordingSession session;
  late VoiceState state;
  late VoiceServerPresence presence;

  setUp(() {
    session = _RecordingSession();
    state = const VoiceState(channelId: 'lounge');
    presence = VoiceServerPresence(
      session,
      VoiceStateAccess(read: () => state, write: (s) => state = s),
    );
  });

  test('a leave and a join in this call reach the session', () {
    presence.apply(
      const api.VoiceParticipantLeft(channelId: 'lounge', userId: 'bob'),
    );
    presence.apply(
      const api.VoiceParticipantJoined(channelId: 'lounge', userId: 'bob'),
    );

    expect(session.calls, ['left bob', 'joined bob']);
  });

  test('another channel, or no call at all, reaches nothing', () {
    presence.apply(
      const api.VoiceParticipantLeft(channelId: 'games', userId: 'bob'),
    );
    state = const VoiceState();
    presence.apply(
      const api.VoiceParticipantLeft(channelId: 'lounge', userId: 'bob'),
    );

    expect(session.calls, isEmpty);
  });
}
