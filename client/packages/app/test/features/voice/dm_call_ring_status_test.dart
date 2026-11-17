// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller sees what its ring is doing: "Calling…" while it rings, and
/// why the call ended when nobody picked up, never "You left this call".
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart';
import 'package:slimm_app/src/features/voice/widgets/call_header_facts.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
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

const _ringing = {'timeout_ms': 30000};
const _allOnDnd = {
  'timeout_ms': 0,
  'do_not_disturb': ['juno'],
};

const _dm = Channel(
  id: 'dm-1',
  name: 'Juno',
  kind: 'dm',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

class _Rig {
  _Rig(this.container, this.events, this.voice);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final FakeVoiceController voice;

  DmCallRingController get ring =>
      container.read(dmCallRingControllerProvider.notifier);
  DmCallRingState get state => container.read(dmCallRingControllerProvider);

  Future<void> ended(api.CallOutcome outcome) async {
    events.add(
      api.CallRingEnded(channelId: 'dm-1', ringId: 'ring-1', outcome: outcome),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

_Rig _rig({Map<String, Object> response = _ringing}) {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  var rings = 0;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(
          ref,
          recording: true,
          initial: const VoiceState(
            state: VoiceSessionState.connected,
            channelId: 'dm-1',
          ),
        ),
      ),
      channelByIdProvider('dm-1').overrideWith((ref) => Stream.value(_dm)),
      voiceRosterProvider('dm-1').overrideWith((ref) => Stream.value([])),
      apiProvider.overrideWith(
        (ref) => testApi(
          (request) async => http.Response(
            jsonEncode({...response, 'ring_id': 'ring-${++rings}'}),
            200,
            headers: {'content-type': 'application/json'},
          ),
          session: api.SessionStore(tokens: _tokens),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final voice =
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;
  return _Rig(container, events, voice);
}

Future<void> _show(WidgetTester tester, _Rig rig, Widget child) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: rig.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

const _rejoin = VoiceRejoinScreen(
  channelId: 'dm-1',
  isDm: true,
  canRetry: true,
  onRetry: _noop,
);

void _noop() {}

void main() {
  test('a ring nobody answers ends as no answer', () async {
    final rig = _rig();
    await rig.ring.startOutgoingRing('dm-1');

    await rig.ended(api.CallOutcome.timedOut);

    expect(rig.state.endedUnansweredIn('dm-1'), OutgoingRingEndReason.noAnswer);
    expect(rig.voice.leaves, 1);
  });

  test('a declined ring says it was declined', () async {
    final rig = _rig();
    await rig.ring.startOutgoingRing('dm-1');

    await rig.ended(api.CallOutcome.declined);

    expect(rig.state.endedUnansweredIn('dm-1'), OutgoingRingEndReason.declined);
  });

  test('a callee on Do not disturb ends the call at once', () async {
    final rig = _rig(response: _allOnDnd);

    await rig.ring.startOutgoingRing('dm-1');

    expect(rig.state.outgoing, isNull);
    expect(
      rig.state.endedUnansweredIn('dm-1'),
      OutgoingRingEndReason.doNotDisturb,
    );
    expect(rig.voice.leaves, 1);
  });

  test('ringing again forgets why the last ring ended', () async {
    final rig = _rig();
    await rig.ring.startOutgoingRing('dm-1');
    await rig.ended(api.CallOutcome.timedOut);

    await rig.ring.startOutgoingRing('dm-1');

    expect(rig.state.endedUnansweredIn('dm-1'), isNull);
    expect(rig.state.isCallingFrom('dm-1'), isTrue);
  });

  testWidgets('the call header says Calling while the ring is out', (
    tester,
  ) async {
    final rig = _rig();
    await _show(
      tester,
      rig,
      const CallHeaderLine(channelId: 'dm-1', showTitle: false),
    );

    await tester.runAsync(() => rig.ring.startOutgoingRing('dm-1'));
    await tester.pump();

    expect(find.text('Calling…'), findsOneWidget);
    expect(find.textContaining('in call'), findsNothing);
  });

  for (final (response, outcome, line) in [
    (_ringing, api.CallOutcome.timedOut, 'No answer'),
    (_ringing, api.CallOutcome.declined, 'Juno declined the call'),
    (_allOnDnd, null, 'Juno is on Do not disturb'),
  ]) {
    testWidgets('the ended call reads "$line", not that you left', (
      tester,
    ) async {
      final rig = _rig(response: response);
      await _show(tester, rig, _rejoin);

      await tester.runAsync(() async {
        await rig.ring.startOutgoingRing('dm-1');
        if (outcome != null) await rig.ended(outcome);
      });
      await tester.pump();

      expect(find.text(line), findsOneWidget);
      expect(find.textContaining('You left this call'), findsNothing);
    });
  }
}
