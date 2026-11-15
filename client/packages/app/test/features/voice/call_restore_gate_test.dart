// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// After the app restarted itself the call is joined again straight away;
/// after a crash the person is asked first.
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
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/dead_voice_session.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _CountingSession extends DeadVoiceSession {
  final joins = <bool>[];

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async => joins.add(microphoneEnabled);
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Future<_CountingSession> _open(
  WidgetTester tester, {
  required bool restart,
  bool muted = false,
}) async {
  final session = _CountingSession();
  final call = CallToRestore(
    channelId: 'voice-1',
    userId: 'user-1',
    at: DateTime.now(),
    muted: muted,
    restart: restart,
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      callToRestoreProvider.overrideWithValue(
        () async => (call: call, channelName: 'Lounge'),
      ),
      callRestoreWatchProvider.overrideWithValue(null),
      mockApiOverride(
        (request) async => request.url.path.endsWith('/voice/token')
            ? _json({
                'url': 'wss://sfu.invalid',
                'room': 'voice-1',
                'token': 'jwt',
                'expires_at': 0,
                'can_publish': true,
              })
            : _json({}),
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
  return session;
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
    final session = await _open(tester, restart: true);

    expect(find.text('Rejoin the call?'), findsNothing);
    expect(session.joins, [true]);
  });

  testWidgets('a restart keeps a muted mic muted', (tester) async {
    final session = await _open(tester, restart: true, muted: true);

    expect(session.joins, [false]);
  });

  testWidgets('after a crash it asks, and Rejoin joins', (tester) async {
    final session = await _open(tester, restart: false);

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

  testWidgets('after a crash, Not now leaves the call alone', (tester) async {
    final session = await _open(tester, restart: false);

    await tester.tap(find.byKey(callRestoreDismissKey));
    await _settle(tester);
    expect(find.text('Rejoin the call?'), findsNothing);
    expect(session.joins, isEmpty);
  });
}
