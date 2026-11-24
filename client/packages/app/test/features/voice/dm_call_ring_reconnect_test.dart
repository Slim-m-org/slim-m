// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A DM ring outlives a dropped socket, and a blocked caller never rings.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
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

Map<String, Object> _outstanding(String ringId, String callerId) => {
  'channel_id': 'dm-1',
  'ring_id': ringId,
  'caller_id': callerId,
  'remaining_ms': 20000,
};

class _Controller extends DmCallRingController {
  _Controller(super.ref);

  @override
  Future<void> ensureChannelLoaded(String channelId) async {}
}

class _Rig {
  _Rig(this.container, this.events, this.voice, this.server);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final FakeVoiceController voice;
  final _Server server;

  DmCallRingController get ring =>
      container.read(dmCallRingControllerProvider.notifier);
  DmCallRingState get state => container.read(dmCallRingControllerProvider);

  Future<void> emit(api.ServerEvent event) async {
    events.add(event);
    await _settle();
  }
}

class _Server {
  List<Map<String, Object>> incoming = [];
  List<String> blocked = [];
  bool failIncoming = false;

  http.Response answer(http.Request request) {
    final path = request.url.path;
    if (failIncoming && path.endsWith('/voice/rings/incoming')) {
      return http.Response(
        '{"error":"down"}',
        500,
        headers: {'content-type': 'application/json'},
      );
    }
    Object? body;
    if (path.endsWith('/voice/rings/incoming')) {
      body = {'rings': incoming};
    } else if (request.method == 'GET' && path.endsWith('/blocks')) {
      body = blocked;
    } else if (path.endsWith('/voice/ring')) {
      body = {'ring_id': 'out-1', 'timeout_ms': 30000};
    }
    if (body == null) return http.Response('', 204);
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<_Rig> _rig({String? inCall, List<String> blocked = const []}) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final server = _Server()..blocked = blocked;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      dmCallRingControllerProvider.overrideWith(_Controller.new),
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(
          ref,
          recording: true,
          initial: inCall == null
              ? null
              : VoiceState(
                  state: VoiceSessionState.connected,
                  channelId: inCall,
                ),
        ),
      ),
      apiProvider.overrideWith(
        (ref) => testApi(
          (request) async => server.answer(request),
          session: api.SessionStore(tokens: _tokens),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  // Held alive for the whole session by the signed-in shell.
  container.read(blocksProvider);
  container.read(dmCallRingControllerProvider);
  await _settle();
  final voice =
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;
  return _Rig(container, events, voice, server);
}

const _ringing = api.CallRinging(
  channelId: 'dm-1',
  ringId: 'ring-1',
  callerId: 'caller-1',
);

void main() {
  test('a ring still outstanding survives a reconnect', () async {
    final rig = await _rig();
    await rig.emit(_ringing);

    rig.ring.holdForReconnect();
    expect(rig.state.visibleIncoming?.ringId, 'ring-1', reason: 'no flicker');
    rig.server.incoming = [_outstanding('ring-1', 'caller-1')];
    await rig.ring.restoreAfterLive();

    expect(rig.state.visibleIncoming?.ringId, 'ring-1');
  });

  test('a ring stays when reading the outstanding rings fails', () async {
    final rig = await _rig();
    await rig.emit(_ringing);
    rig.ring.holdForReconnect();

    rig.server.failIncoming = true;
    await rig.ring.restoreAfterLive();

    expect(rig.state.visibleIncoming?.ringId, 'ring-1');
  });

  test('a ring that began while disconnected shows once live', () async {
    final rig = await _rig();
    rig.ring.holdForReconnect();

    rig.server.incoming = [_outstanding('ring-2', 'caller-2')];
    await rig.ring.restoreAfterLive();

    expect(rig.state.visibleIncoming?.ringId, 'ring-2');
    expect(rig.state.visibleIncoming?.callerId, 'caller-2');
  });

  test('a ring that ended while disconnected goes once live', () async {
    final rig = await _rig();
    await rig.emit(_ringing);
    rig.ring.holdForReconnect();

    await rig.ring.restoreAfterLive();

    expect(rig.state.visibleIncoming, isNull);
  });

  test(
    'an outgoing ring held across a reconnect still ends the call',
    () async {
      final rig = await _rig(inCall: 'dm-1');
      await rig.ring.startOutgoingRing('dm-1');
      expect(rig.state.isCallingFrom('dm-1'), isTrue);

      rig.ring.holdForReconnect();
      await rig.ring.restoreAfterLive();
      await rig.emit(
        const api.CallRingEnded(
          channelId: 'dm-1',
          ringId: 'out-1',
          outcome: api.CallOutcome.declined,
        ),
      );

      expect(rig.voice.leaves, 1, reason: 'nobody answered, so it hangs up');
      expect(
        rig.state.endedUnansweredIn('dm-1'),
        OutgoingRingEndReason.declined,
      );
    },
  );

  test(
    'a held outgoing ring stops once the caller is out of the call',
    () async {
      final rig = await _rig(inCall: 'dm-1');
      await rig.ring.startOutgoingRing('dm-1');
      rig.ring.holdForReconnect();

      rig.voice.hangUp();
      await _settle();

      expect(rig.state.isCallingFrom('dm-1'), isFalse);
    },
  );

  test('a ring from a blocked caller never shows', () async {
    final rig = await _rig(blocked: ['caller-1']);

    await rig.emit(_ringing);

    expect(rig.state.visibleIncoming, isNull);
  });

  test('blocking the caller takes their ring down', () async {
    final rig = await _rig();
    await rig.emit(_ringing);
    expect(rig.state.visibleIncoming?.ringId, 'ring-1');

    await rig.container.read(blocksProvider.notifier).block('caller-1');
    await _settle();

    expect(rig.state.visibleIncoming, isNull);
  });

  test('a ring read back after a reconnect skips a blocked caller', () async {
    final rig = await _rig(blocked: ['caller-1']);
    rig.ring.holdForReconnect();

    rig.server.incoming = [_outstanding('ring-1', 'caller-1')];
    await rig.ring.restoreAfterLive();

    expect(rig.state.visibleIncoming, isNull);
  });
}
