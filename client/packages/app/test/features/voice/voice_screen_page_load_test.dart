// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A web page load straight onto a voice channel shows it without joining:
/// reloading must not put anyone back in a call they did not click.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/launch_route.dart';
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
  var joins = 0;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async => joins++;
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Future<_CountingSession> _open(WidgetTester tester, String launchedAt) async {
  final session = _CountingSession();
  final container = ProviderContainer(
    overrides: [
      launchRouteProvider.overrideWithValue(LaunchRoute(launchedAt)),
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride(
        (request) async => request.url.path.endsWith('/voice/token')
            ? _json({
                'url': 'wss://sfu.invalid',
                'room': 'channel-1',
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
        home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return session;
}

void main() {
  testWidgets('a page load onto the channel shows it without joining', (
    tester,
  ) async {
    final session = await _open(tester, '/channels/channel-1');

    expect(session.joins, 0);
    expect(find.text('Join muted'), findsOneWidget, reason: 'one tap away');
  });

  testWidgets('arriving any other way still joins', (tester) async {
    final session = await _open(tester, '/');

    expect(session.joins, 1);
  });
}
