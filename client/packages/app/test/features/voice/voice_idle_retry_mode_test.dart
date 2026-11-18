// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle pane's Try again repeats the join that failed: a plain Join
/// retries with the mic on, Join muted retries muted.
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

class _MicSession extends DeadVoiceSession {
  final micAtJoin = <bool>[];

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) async => micAtJoin.add(microphoneEnabled);
}

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The first token request fails, so the first join lands on Try again.
Future<_MicSession> _open(WidgetTester tester) async {
  final session = _MicSession();
  var tokenRequests = 0;
  final container = ProviderContainer(
    overrides: [
      launchRouteProvider.overrideWithValue(LaunchRoute('/channels/channel-1')),
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (!request.url.path.endsWith('/voice/token')) return _json({});
        if (tokenRequests++ == 0) {
          return _json({'error': 'unavailable'}, status: 503);
        }
        return _json({
          'url': 'wss://sfu.invalid',
          'room': 'channel-1',
          'token': 'jwt',
          'expires_at': 0,
          'can_publish': true,
        });
      }),
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
  await _settle(tester);
  return session;
}

void main() {
  for (final (button, mic) in [('Join', true), ('Join muted', false)]) {
    testWidgets('Try again after $button joins the same way', (tester) async {
      final session = await _open(tester);
      await tester.tap(find.text(button));
      await _settle(tester);
      expect(session.micAtJoin, isEmpty, reason: 'the first token failed');

      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(session.micAtJoin, [mic]);
    });
  }
}
