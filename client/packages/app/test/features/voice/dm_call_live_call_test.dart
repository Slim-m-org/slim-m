// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Calling a DM whose call is already live joins it: nothing rings, nothing
/// hangs the caller up, and an old "No answer" does not outlive a later call.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/dm_call.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_activity.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_start.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/fake_voice.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

const _juno = VoiceParticipant(
  identity: 'juno',
  name: 'Juno',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

class _KnownActivity extends DmCallActivityController {
  _KnownActivity(super.ref, Map<String, bool> known) {
    state = known;
  }
}

class _Rig {
  _Rig(this.container, this.events, this.voice, this.rings);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final FakeVoiceController voice;

  /// Ring requests the server saw.
  final List<String> rings;

  DmCallRingController get ring =>
      container.read(dmCallRingControllerProvider.notifier);
  DmCallRingState get state => container.read(dmCallRingControllerProvider);

  Future<void> ended(String ringId, api.CallOutcome outcome) async {
    events.add(
      api.CallRingEnded(channelId: 'dm-1', ringId: ringId, outcome: outcome),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

_Rig _rig({
  Map<String, bool> activity = const {},
  VoiceState? initial,
  Map<String, Object> response = const {'timeout_ms': 30000},
}) {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final rings = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      dmCallActivityProvider.overrideWith(
        (ref) => _KnownActivity(ref, activity),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(ref, recording: true, initial: initial),
      ),
      apiProvider.overrideWith(
        (ref) => testApi((request) async {
          rings.add(request.url.path);
          return http.Response(
            jsonEncode({...response, 'ring_id': 'ring-${rings.length}'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }, session: api.SessionStore(tokens: _tokens)),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(dmCallRingControllerProvider);
  final voice =
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;
  return _Rig(container, events, voice, rings);
}

const _inCallWithJuno = VoiceState(
  state: VoiceSessionState.connected,
  channelId: 'dm-1',
  participants: [_juno],
);

void main() {
  test('calling a DM whose call is live opens it without ringing', () async {
    final rig = _rig(activity: {'dm-1': true});

    startDmCall(rig.container.read, 'dm-1');
    await Future<void>.delayed(Duration.zero);

    expect(rig.container.read(dmCallOpenProvider), 'dm-1');
    expect(rig.rings, isEmpty);
  });

  test('calling a DM with nobody in its call still rings', () async {
    final rig = _rig(activity: {'dm-1': false});

    startDmCall(rig.container.read, 'dm-1');
    await Future<void>.delayed(Duration.zero);

    expect(rig.rings, ['/channels/dm-1/voice/ring']);
  });

  test(
    'a ring that times out while someone is in the call hangs nobody up',
    () async {
      final rig = _rig(initial: _inCallWithJuno);
      await rig.ring.startOutgoingRing('dm-1');

      await rig.ended('ring-1', api.CallOutcome.timedOut);

      expect(rig.voice.leaves, 0);
      expect(rig.state.endedUnansweredIn('dm-1'), isNull);
    },
  );

  test('everyone else on Do not disturb does not end a live call', () async {
    final rig = _rig(
      initial: _inCallWithJuno,
      response: const {
        'timeout_ms': 0,
        'do_not_disturb': ['cleo'],
      },
    );

    await rig.ring.startOutgoingRing('dm-1');

    expect(rig.voice.leaves, 0);
    expect(rig.state.endedUnansweredIn('dm-1'), isNull);
  });

  test(
    'joining the call later forgets why the last ring went unanswered',
    () async {
      final rig = _rig(
        initial: const VoiceState(
          state: VoiceSessionState.connected,
          channelId: 'dm-1',
        ),
      );
      await rig.ring.startOutgoingRing('dm-1');
      await rig.ended('ring-1', api.CallOutcome.timedOut);
      expect(
        rig.state.endedUnansweredIn('dm-1'),
        OutgoingRingEndReason.noAnswer,
      );

      rig.voice.connect(channelId: 'dm-1');
      await Future<void>.delayed(Duration.zero);

      expect(rig.state.endedUnansweredIn('dm-1'), isNull);
    },
  );

  test('a later ring in that DM being answered forgets it too', () async {
    final rig = _rig(
      initial: const VoiceState(
        state: VoiceSessionState.connected,
        channelId: 'dm-1',
      ),
    );
    await rig.ring.startOutgoingRing('dm-1');
    await rig.ended('ring-1', api.CallOutcome.timedOut);

    await rig.ended('ring-2', api.CallOutcome.answered);

    expect(rig.state.endedUnansweredIn('dm-1'), isNull);
  });
}
