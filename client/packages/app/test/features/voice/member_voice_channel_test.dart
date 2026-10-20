// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which voice channel a member is in, derived from the rosters the rail
/// already keeps: only channels the viewer can see, live-updating, no poll.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/member_voice_channel.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

Channel voiceChannel(String id, String name) => Channel(
  id: id,
  name: name,
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

api.VoiceRosterParticipant who(String id) =>
    api.VoiceRosterParticipant(userId: id, displayName: id);

ProviderContainer _container({
  required List<Channel> visible,
  required Map<String, Stream<List<api.VoiceRosterParticipant>>> rosters,
  VoiceState voice = const VoiceState(),
}) {
  final container = ProviderContainer(
    overrides: [
      visibleVoiceChannelsProvider.overrideWith((_) => Stream.value(visible)),
      voiceRosterProvider.overrideWith(
        (ref, id) => rosters[id] ?? const Stream.empty(),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, voice),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<Channel?> _chipFor(ProviderContainer c, String userId) async {
  c.listen(memberVoiceChannelProvider(userId), (_, _) {});
  await pumpEventQueue();
  return c.read(memberVoiceChannelProvider(userId));
}

void main() {
  final lounge = voiceChannel('v1', 'lounge');
  final games = voiceChannel('v2', 'games');

  test('a member on a roster maps to that channel', () async {
    final c = _container(
      visible: [lounge, games],
      rosters: {
        'v2': Stream.value([who('ada')]),
        'v1': Stream.value([who('bob')]),
      },
    );
    expect((await _chipFor(c, 'ada'))?.name, 'games');
    expect((await _chipFor(c, 'bob'))?.name, 'lounge');
  });

  test('a member in no call has no channel', () async {
    final c = _container(
      visible: [lounge],
      rosters: {
        'v1': Stream.value([who('bob')]),
      },
    );
    expect(await _chipFor(c, 'ada'), isNull);
  });

  test('a channel the viewer cannot see is never consulted', () async {
    final c = _container(
      visible: [lounge],
      rosters: {
        'secret': Stream.value([who('ada')]),
      },
    );
    expect(await _chipFor(c, 'ada'), isNull);
  });

  test('the chip follows the roster live, with no poll of its own', () async {
    final roster = StreamController<List<api.VoiceRosterParticipant>>();
    addTearDown(roster.close);
    final c = _container(visible: [lounge], rosters: {'v1': roster.stream});
    expect(await _chipFor(c, 'ada'), isNull);
    roster.add([who('ada')]);
    await pumpEventQueue();
    expect(c.read(memberVoiceChannelProvider('ada'))?.name, 'lounge');
    roster.add(const []);
    await pumpEventQueue();
    expect(c.read(memberVoiceChannelProvider('ada')), isNull);
  });

  test('the joined channel reads the live session, not the snapshot', () async {
    final c = _container(
      visible: [lounge],
      rosters: {'v1': Stream.value(const [])},
      voice: const VoiceState(
        state: VoiceSessionState.connected,
        channelId: 'v1',
        participants: [
          VoiceParticipant(
            identity: 'ada',
            name: 'Ada',
            isSpeaking: false,
            isMuted: false,
            isLocal: false,
            isScreenSharing: false,
          ),
        ],
      ),
    );
    expect((await _chipFor(c, 'ada'))?.name, 'lounge');
  });
}
