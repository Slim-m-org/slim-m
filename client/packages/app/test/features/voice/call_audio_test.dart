// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module hearing a call as text (decision 0105): the state kept from the
/// route and the `voice.call_audio` frame, the control that asks, the prompt
/// everyone else gets, and the banner everyone sees while it is on.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_banner.dart';
import 'package:slimm_app/src/widgets/status_banner.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_prompt.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_start.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 4102444800000,
);

Map<String, dynamic> _session({
  bool on = false,
  List<String> included = const ['asker'],
  List<String> pending = const ['me'],
}) => {
  'module_id': 'transcript',
  'module_name': 'Transcript',
  'purpose': 'Writes down what is said.',
  'keeps': 'The text, for 30 days.',
  'status': on ? 'on' : 'asking',
  'asked_by': 'asker',
  'included': included,
  'pending': pending,
  'expires_at_ms': DateTime.now().millisecondsSinceEpoch + 60000,
  'full': false,
};

class _Rig {
  _Rig(this.container, this.events, this.requests);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final List<String> requests;
}

/// A call in channel `c1` as `me`; the route answers [status] until told otherwise.
Future<_Rig> _pump(
  WidgetTester tester,
  Widget Function() child, {
  Map<String, dynamic>? session,
  List<Map<String, dynamic>> startable = const [],
  double width = 1000,
  bool hidden = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final requests = <String>[];
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      voiceFlagsProvider.overrideWithValue(const VoiceFlags(channelId: 'c1')),
      userProfileProvider.overrideWith((ref, id) async => null),
      if (hidden)
        ownVisibilityProvider.overrideWithValue(api.PresenceVisibility.hidden),
      apiProvider.overrideWith((ref) {
        final client = testApi((request) async {
          requests.add('${request.method} ${request.url.path} ${request.body}');
          if (request.method == 'DELETE') return http.Response('', 204);
          final allowed =
              request.method == 'PUT' &&
              jsonDecode(request.body)['allow'] == false;
          return http.Response(
            jsonEncode({
              'session': allowed ? null : session,
              'startable': startable,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }, session: api.SessionStore(tokens: _tokens));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionProvider).set(_tokens);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: Stack(children: [child()])),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Rig(container, events, requests);
}

api.VoiceCallAudioChanged _frame(
  Map<String, dynamic>? state, {
  String? ended,
}) => api.VoiceCallAudioChanged(
  channelId: 'c1',
  state: state == null ? null : api.CallAudioState.fromJson(state),
  ended: ended,
);

void main() {
  group('callAudioProvider', () {
    test(
      'reads the route, then follows the frame and asks again when it ends',
      () async {
        final events = StreamController<api.ServerEvent>.broadcast();
        addTearDown(events.close);
        var reads = 0;
        final container = ProviderContainer(
          overrides: [
            liveEventsProvider.overrideWithValue(events.stream),
            apiProvider.overrideWith((ref) {
              final client = testApi((request) async {
                reads++;
                return http.Response(
                  jsonEncode({'session': null, 'startable': <Object>[]}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }, session: api.SessionStore(tokens: _tokens));
              ref.onDispose(client.close);
              return client;
            }),
          ],
        );
        addTearDown(container.dispose);
        final sub = container.listen(callAudioProvider('c1'), (_, __) {});
        addTearDown(sub.close);
        await Future<void>.delayed(Duration.zero);
        expect(reads, 1);
        expect(sub.read().session, isNull);

        events.add(_frame(_session(on: true)));
        await Future<void>.delayed(Duration.zero);
        expect(sub.read().session!.isOn, isTrue);
        events.add(
          const api.VoiceCallAudioChanged(channelId: 'other', state: null),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          sub.read().session,
          isNotNull,
          reason: 'another channel is not ours',
        );

        events.add(_frame(null, ended: 'lapsed'));
        await Future<void>.delayed(Duration.zero);
        expect(sub.read().session, isNull);
        expect(sub.read().ended, 'lapsed');
        expect(
          reads,
          2,
          reason: 'the end reads the route for what can start next',
        );
      },
    );

    test(
      'a read that left before a newer frame does not overwrite it',
      () async {
        final events = StreamController<api.ServerEvent>.broadcast();
        addTearDown(events.close);
        final reply = Completer<void>();
        final firstRead = Completer<void>();
        var reads = 0;
        final container = ProviderContainer(
          overrides: [
            liveEventsProvider.overrideWithValue(events.stream),
            apiProvider.overrideWith((ref) {
              final client = testApi((request) async {
                reads++;
                if (reads == 1) {
                  firstRead.complete();
                  await reply.future;
                }
                return http.Response(
                  jsonEncode({'session': null, 'startable': <Object>[]}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }, session: api.SessionStore(tokens: _tokens));
              ref.onDispose(client.close);
              return client;
            }),
          ],
        );
        addTearDown(container.dispose);
        final sub = container.listen(callAudioProvider('c1'), (_, __) {});
        addTearDown(sub.close);
        await firstRead.future;

        events.add(_frame(_session(on: true)));
        await Future<void>.delayed(Duration.zero);
        expect(sub.read().session!.isOn, isTrue);
        reply.complete();
        await pumpEventQueue();

        expect(
          sub.read().session,
          isNotNull,
          reason: 'the older read must not wipe what the frame said',
        );
      },
    );
  });

  group('CallAudioPrompt', () {
    testWidgets('asks someone left out, with the words and a countdown', (
      tester,
    ) async {
      await _pump(tester, () => const CallAudioPrompt(), session: _session());
      expect(find.byKey(CallAudioPrompt.cardKey), findsOneWidget);
      expect(find.text('Let Transcript hear this call?'), findsOneWidget);
      expect(find.text('Writes down what is said.'), findsOneWidget);
      expect(find.text('It keeps: The text, for 30 days.'), findsOneWidget);
      expect(find.byKey(CallAudioPrompt.countdownKey), findsOneWidget);
      expect(find.byKey(CallAudioPrompt.hiddenNoteKey), findsNothing);
    });

    testWidgets('says the module will see a hidden member was there', (
      tester,
    ) async {
      await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: _session(),
        hidden: true,
      );
      expect(find.byKey(CallAudioPrompt.hiddenNoteKey), findsOneWidget);
    });

    testWidgets('is silent for someone who already said yes', (tester) async {
      await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: _session(included: ['asker', 'me'], pending: []),
      );
      expect(find.byKey(CallAudioPrompt.cardKey), findsNothing);
    });

    testWidgets('Allow and Not now send the answer', (tester) async {
      final rig = await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: _session(),
      );
      await tester.tap(find.byKey(CallAudioPrompt.allowKey));
      await tester.pump();
      await tester.pump();
      expect(
        rig.requests.last,
        'PUT /channels/c1/voice/call-audio/consent {"allow":true}',
      );
      await tester.tap(find.byKey(CallAudioPrompt.notNowKey));
      await tester.pump();
      await tester.pump();
      expect(
        rig.requests,
        contains('PUT /channels/c1/voice/call-audio/consent {"allow":false}'),
      );
    });

    testWidgets('Escape leaves them out without answering no', (tester) async {
      final rig = await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: _session(),
      );
      final before = rig.requests.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(CallAudioPrompt.cardKey), findsNothing);
      expect(rig.requests.length, before, reason: 'nothing was sent');
    });

    testWidgets('counts down the seconds to answer', (tester) async {
      await _pump(tester, () => const CallAudioPrompt(), session: _session());
      final text = find.byKey(CallAudioPrompt.countdownKey);
      final first = int.parse(
        (tester.widget<Text>(text).data!).split(' ').first,
      );
      await tester.pump(const Duration(seconds: 3));
      final later = int.parse(
        (tester.widget<Text>(text).data!).split(' ').first,
      );
      expect(first - later, 3);
    });

    testWidgets('takes the whole screen on a phone', (tester) async {
      await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: _session(),
        width: 400,
      );
      expect(tester.getSize(find.byKey(CallAudioPrompt.cardKey)).width, 400);
    });

    testWidgets('puts the answer at the bottom of a phone screen', (
      tester,
    ) async {
      await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: _session(),
        width: 400,
      );
      final allow = tester.getRect(find.byKey(CallAudioPrompt.allowKey));
      expect(allow.bottom, greaterThan(900 * 0.8));
    });

    testWidgets('follows the session while it is showing', (tester) async {
      final session = _session();
      final rig = await _pump(
        tester,
        () => const CallAudioPrompt(),
        session: session,
      );
      rig.events.add(_frame({...session, 'purpose': 'Takes the minutes.'}));
      await tester.pump();
      await tester.pump();
      expect(find.text('Takes the minutes.'), findsOneWidget);
    });

    testWidgets('floats as a card on a wide window', (tester) async {
      await _pump(tester, () => const CallAudioPrompt(), session: _session());
      final card = tester.getRect(find.byKey(CallAudioPrompt.cardKey));
      expect(card.width, lessThanOrEqualTo(420));
      expect(card.top, lessThan(100));
    });
  });

  group('CallAudioBanner', () {
    testWidgets('says who is hearing the call, with Stop', (tester) async {
      final rig = await _pump(
        tester,
        () => const CallAudioBanner(channelId: 'c1'),
        session: _session(on: true, included: ['asker', 'me'], pending: []),
      );
      expect(find.text('Transcript is hearing this call'), findsOneWidget);
      await tester.tap(find.byKey(CallAudioBanner.stopKey));
      await tester.pump();
      expect(rig.requests, contains('DELETE /channels/c1/voice/call-audio '));
    });

    testWidgets('tells someone left out, with Allow', (tester) async {
      await _pump(
        tester,
        () => const CallAudioBanner(channelId: 'c1'),
        session: _session(on: true),
      );
      expect(find.text('Your voice is not included'), findsOneWidget);
      expect(find.byKey(CallAudioBanner.allowKey), findsOneWidget);
    });

    testWidgets('counts who has answered while it waits', (tester) async {
      await _pump(
        tester,
        () => const CallAudioBanner(channelId: 'c1'),
        session: _session(included: ['asker'], pending: ['me', 'third']),
      );
      expect(find.text('Waiting for everyone (1 of 3)'), findsOneWidget);
    });

    testWidgets('after a no it says nothing started, never who', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        () => const CallAudioBanner(channelId: 'c1'),
      );
      expect(find.byKey(const ValueKey('call-audio-ended')), findsNothing);
      rig.events.add(_frame(null, ended: 'declined'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Not everyone agreed, so nothing is listening.'),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('call-audio-ended')),
          matching: find.byKey(StatusBanner.dismissKey),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('call-audio-ended')), findsNothing);
    });

    testWidgets('a frame turns it on live', (tester) async {
      final rig = await _pump(
        tester,
        () => const CallAudioBanner(channelId: 'c1'),
      );
      expect(find.byKey(const ValueKey('call-audio-on')), findsNothing);
      rig.events.add(
        _frame(_session(on: true, included: ['asker', 'me'], pending: [])),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('call-audio-on')), findsOneWidget);
    });
  });

  group('CallAudioStartControl', () {
    const module = {
      'module_id': 'transcript',
      'module_name': 'Transcript',
      'purpose': 'Writes down what is said.',
      'keeps': 'The text, for 30 days.',
    };

    testWidgets('is absent when nothing can be started', (tester) async {
      await _pump(
        tester,
        () => Consumer(
          builder: (context, ref, _) =>
              callAudioStartRow(ref, 'c1') ?? const Text('nothing'),
        ),
      );
      expect(find.text('nothing'), findsOneWidget);
      expect(find.byKey(CallAudioStartControl.buttonKey), findsNothing);
    });

    testWidgets('asks only after the confirm sheet shows the words', (
      tester,
    ) async {
      final rig = await _pump(
        tester,
        () => Consumer(
          builder: (context, ref, _) =>
              callAudioStartRow(ref, 'c1') ?? const SizedBox.shrink(),
        ),
        startable: [module],
      );
      await tester.tap(find.byKey(CallAudioStartControl.buttonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Writes down what is said.'), findsOneWidget);
      expect(find.text('It keeps: The text, for 30 days.'), findsOneWidget);
      expect(rig.requests.where((r) => r.startsWith('POST')), isEmpty);

      await tester.tap(find.byKey(const ValueKey('call-audio-ask-transcript')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        rig.requests.where((r) => r.startsWith('POST')).single,
        'POST /channels/c1/voice/call-audio {"module_id":"transcript"}',
      );
    });
  });
}
