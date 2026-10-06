// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's side of a DM ring: which outcomes hang the caller up, that only
/// the matching ring and channel count, that `decline` reaches the server, and
/// that a `call.ring_ended` frame beating the ring response is not forgotten.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

class _RecordingVoice extends VoiceController {
  _RecordingVoice(super.ref);

  int leaves = 0;

  @override
  Future<void> leave() async {
    leaves++;
    state = const VoiceState();
  }
}

class _Rig {
  _Rig(this.container, this.events, this.voice, this.requests, this.gate);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final _RecordingVoice voice;
  final List<String> requests;
  final Completer<void>? gate;

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

/// [gated] holds the ring response until `gate` completes, so a frame can
/// arrive first.
_Rig _rig({bool gated = false, String? inCall = 'dm-1'}) {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <String>[];
  final gate = gated ? Completer<void>() : null;
  late _RecordingVoice voice;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      voiceControllerProvider.overrideWith((ref) {
        voice = _RecordingVoice(ref);
        if (inCall != null) voice.state = VoiceState(channelId: inCall);
        return voice;
      }),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: api.SessionStore(tokens: _tokens),
          httpClient: MockClient((request) async {
            requests.add('${request.method} ${request.url.path}');
            await gate?.future;
            if (request.url.path.endsWith('/decline')) {
              return http.Response('', 204);
            }
            return http.Response(
              jsonEncode({'ring_id': 'ring-1', 'timeout_ms': 30000}),
              201,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  voice = container.read(voiceControllerProvider.notifier) as _RecordingVoice;
  return _Rig(container, events, voice, requests, gate);
}

Future<_Rig> _ringing({String? inCall = 'dm-1'}) async {
  final rig = _rig(inCall: inCall);
  await rig.ring.startOutgoingRing('dm-1');
  expect(rig.state.outgoing?.ringId, 'ring-1');
  return rig;
}

void main() {
  for (final outcome in [api.CallOutcome.declined, api.CallOutcome.timedOut]) {
    test('a ring that ends $outcome hangs the caller up', () async {
      final rig = await _ringing();

      await rig.ended('ring-1', outcome);

      expect(rig.state.outgoing, isNull);
      expect(rig.voice.leaves, 1);
    });
  }

  for (final outcome in [api.CallOutcome.answered, api.CallOutcome.canceled]) {
    test('a ring that ends $outcome clears without hanging up', () async {
      final rig = await _ringing();

      await rig.ended('ring-1', outcome);

      expect(rig.state.outgoing, isNull);
      expect(rig.voice.leaves, 0);
    });
  }

  test('a different ring ending leaves this one ringing', () async {
    final rig = await _ringing();

    await rig.ended('ring-other', api.CallOutcome.declined);

    expect(rig.state.outgoing?.ringId, 'ring-1');
    expect(rig.voice.leaves, 0);
  });

  test(
    'a decline does not hang up a call the caller moved to another channel',
    () async {
      final rig = await _ringing(inCall: 'dm-2');

      await rig.ended('ring-1', api.CallOutcome.declined);

      expect(rig.state.outgoing, isNull);
      expect(rig.voice.leaves, 0);
    },
  );

  test('decline tells the server and clears the incoming ring', () async {
    final rig = _rig();
    const incoming = IncomingDmCallRing(
      channelId: 'dm-1',
      ringId: 'ring-9',
      callerId: 'caller-1',
    );

    await rig.ring.decline(incoming);

    expect(rig.requests, ['POST /channels/dm-1/voice/ring/decline']);
    expect(rig.state.incoming, isNull);
  });

  test(
    'a decline that beats the ring response leaves nothing ringing',
    () async {
      final rig = _rig(gated: true);
      final started = rig.ring.startOutgoingRing('dm-1');
      await Future<void>.delayed(Duration.zero);

      await rig.ended('ring-1', api.CallOutcome.declined);
      rig.gate!.complete();
      await started;

      expect(rig.state.outgoing, isNull);
      expect(rig.voice.leaves, 1, reason: 'the declined ring still hangs up');
    },
  );

  test(
    'an answer that beats the ring response leaves nothing ringing',
    () async {
      final rig = _rig(gated: true);
      final started = rig.ring.startOutgoingRing('dm-1');
      await Future<void>.delayed(Duration.zero);

      await rig.ended('ring-1', api.CallOutcome.answered);
      rig.gate!.complete();
      await started;

      expect(rig.state.outgoing, isNull);
      expect(rig.voice.leaves, 0);
    },
  );
}
