// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// After the app restarted itself the call is joined again straight away;
/// after a crash the person is asked first. Either way it comes back muted and
/// deafened as it was, and through the transcription notice a join owes.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_restore_gate.dart';
import 'package:slimm_app/src/features/voice/widgets/transcription_notice.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../support/fake_api.dart';
import 'fake_voice_session.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _noticeTitle = 'Calls in this Space are transcribed';

/// Records whether the mic opened; one that [connects] reaches connected as the real session does.
class _CountingSession extends FakeSession {
  _CountingSession({this.connects = false});

  final bool connects;
  final joins = <bool>[];

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async {
    joins.add(microphoneEnabled);
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    if (connects) emitState(VoiceSessionState.connected);
  }
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Future<(_CountingSession, ProviderContainer)> _open(
  WidgetTester tester, {
  required bool restart,
  bool muted = false,
  bool deafened = false,
  bool noticeDue = false,
  bool connects = false,
  List<String>? answers,
}) async {
  final session = _CountingSession(connects: connects);
  // Read from its stored form, as a start does, so a field the record drops is lost here too.
  final call = CallToRestore.decode(
    jsonEncode({
      'channel': 'voice-1',
      'user': 'user-1',
      'at': DateTime.now().toUtc().toIso8601String(),
      'muted': muted,
      'deafened': deafened,
      'restart': restart,
    }),
  )!;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      callToRestoreProvider.overrideWithValue(
        () async => (call: call, channelName: 'Lounge'),
      ),
      callRestoreWatchProvider.overrideWithValue(null),
      answerCallToRestoreProvider.overrideWithValue(
        () async => answers?.add('answered'),
      ),
      mockApiOverride(
        (request) async => switch (request.url.path) {
          final path when path.endsWith('/voice/token') => _json({
            'url': 'wss://sfu.invalid',
            'room': 'voice-1',
            'token': 'jwt',
            'expires_at': 0,
            'can_publish': true,
          }),
          '/voice/transcription-notice' => _json({
            'mode': noticeDue ? 'always' : 'off',
            'acknowledged': false,
          }),
          '/voice/transcription-notice/ack' => http.Response('', 204),
          _ => _json({}),
        },
      ),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const CallRestoreGate(child: Scaffold(body: SizedBox())),
      ),
    ),
  );
  await _settle(tester);
  return (session, container);
}

/// Leaves a connected call, whose timers must end before the test does.
Future<void> _hangUp(WidgetTester tester, ProviderContainer container) async {
  await container.read(voiceControllerProvider.notifier).leave();
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('after a restart the call is joined without asking', (
    tester,
  ) async {
    final (session, _) = await _open(tester, restart: true);

    expect(find.text('Rejoin the call?'), findsNothing);
    expect(session.joins, [true]);
  });

  testWidgets('a restart keeps a muted mic muted', (tester) async {
    final (session, _) = await _open(tester, restart: true, muted: true);

    expect(session.joins, [false]);
  });

  testWidgets('after a crash it asks, and Rejoin joins', (tester) async {
    final (session, _) = await _open(tester, restart: false);

    expect(find.text('Rejoin the call?'), findsOneWidget);
    expect(
      find.text('slim-m closed while you were in Lounge.'),
      findsOneWidget,
    );
    expect(session.joins, isEmpty);

    await tester.tap(find.byKey(callRestoreRejoinKey));
    await _settle(tester);
    expect(session.joins, [true]);
  });

  testWidgets('the offer is cleared only once it is answered', (tester) async {
    final answers = <String>[];
    await _open(tester, restart: false, answers: answers);

    expect(find.text('Rejoin the call?'), findsOneWidget);
    expect(answers, isEmpty, reason: 'a reload now must offer it again');

    await tester.tap(find.byKey(callRestoreDismissKey));
    await _settle(tester);
    expect(answers, ['answered']);
  });

  testWidgets('a restart clears the offer as it rejoins', (tester) async {
    final answers = <String>[];
    final (session, _) = await _open(tester, restart: true, answers: answers);

    expect(answers, ['answered']);
    expect(session.joins, [true]);
  });

  testWidgets('after a crash, Not now leaves the call alone', (tester) async {
    final (session, _) = await _open(tester, restart: false);

    await tester.tap(find.byKey(callRestoreDismissKey));
    await _settle(tester);
    expect(find.text('Rejoin the call?'), findsNothing);
    expect(session.joins, isEmpty);
  });

  testWidgets('a restart keeps a deafened call deafened', (tester) async {
    final (session, container) = await _open(
      tester,
      restart: true,
      muted: true,
      deafened: true,
      connects: true,
    );

    expect(session.joins, [false]);
    expect(session.deafened, isTrue);
    expect(container.read(voiceControllerProvider).deafened, isTrue);
    await _hangUp(tester, container);
  });

  testWidgets('a call that was not deafened comes back hearing', (
    tester,
  ) async {
    final (session, container) = await _open(
      tester,
      restart: true,
      connects: true,
    );

    expect(session.joins, [true]);
    expect(session.deafened, isFalse);
    await _hangUp(tester, container);
  });

  testWidgets('a restart asks the transcription notice a join owes', (
    tester,
  ) async {
    final (session, _) = await _open(tester, restart: true, noticeDue: true);

    expect(find.text(_noticeTitle), findsOneWidget);
    expect(session.joins, isEmpty);

    await tester.tap(find.byKey(transcriptionNoticeJoinKey));
    await _settle(tester);
    expect(session.joins, [true]);
  });

  testWidgets('cancelling the notice leaves the call', (tester) async {
    final (session, _) = await _open(tester, restart: true, noticeDue: true);

    await tester.tap(find.byKey(transcriptionNoticeCancelKey));
    await _settle(tester);
    expect(find.text(_noticeTitle), findsNothing);
    expect(session.joins, isEmpty);
  });

  testWidgets('after a crash, Rejoin still asks the notice', (tester) async {
    final (session, _) = await _open(tester, restart: false, noticeDue: true);

    await tester.tap(find.byKey(callRestoreRejoinKey));
    await _settle(tester);
    expect(find.text(_noticeTitle), findsOneWidget);
    expect(session.joins, isEmpty);

    await tester.tap(find.byKey(transcriptionNoticeJoinKey));
    await _settle(tester);
    expect(session.joins, [true]);
  });
}
