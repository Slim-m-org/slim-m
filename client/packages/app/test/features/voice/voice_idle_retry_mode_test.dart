// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle pane's Try again repeats the join that failed: a plain Join, or
/// the automatic join of a sidebar click, retries with the mic on; Join muted
/// retries muted.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_call_history.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/launch_route.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/dead_voice_session.dart';
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

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

typedef _Rig = ({_MicSession session, ProviderContainer container});

/// The first token request fails, so the first join lands on Try again. A
/// page load waits for a tap; a sidebar click ([pageLoad] false) joins itself.
Future<_Rig> _open(WidgetTester tester, {bool pageLoad = true}) async {
  final session = _MicSession();
  var tokenRequests = 0;
  final container = ProviderContainer(
    overrides: [
      launchRouteProvider.overrideWithValue(
        LaunchRoute(pageLoad ? '/channels/channel-1' : '/channels'),
      ),
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
      voiceCallHistoryProvider.overrideWith(
        (ref, channelId) async => const VoiceCallHistory(
          retentionDays: 0,
          canvasObjectCount: 0,
          calls: [],
        ),
      ),
      syncControllerProvider.overrideWith(NoopSyncController.new),
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
  return (session: session, container: container);
}

Future<void> _untilJoinFailed(WidgetTester tester, _Rig rig) => waitUntil(
  tester,
  () => rig.container.read(voiceControllerProvider).error != null,
  reason: 'the first token request never failed the join',
);

Future<void> _retry(WidgetTester tester, _Rig rig) async {
  await tester.tap(find.text('Try again'));
  await waitUntil(
    tester,
    () => rig.session.micAtJoin.isNotEmpty,
    reason: 'Try again never reached the session',
  );
}

void main() {
  for (final (button, mic) in [('Join', true), ('Join muted', false)]) {
    testWidgets('Try again after $button joins the same way', (tester) async {
      final rig = await _open(tester);
      await waitUntil(
        tester,
        () =>
            rig.container.read(voiceCallHistoryProvider('channel-1')).hasValue,
        reason: 'the call history never loaded',
      );
      await tester.tap(find.text(button));
      await _untilJoinFailed(tester, rig);
      expect(rig.session.micAtJoin, isEmpty, reason: 'the first token failed');

      await _retry(tester, rig);
      expect(rig.session.micAtJoin, [mic]);
    });
  }

  testWidgets('Try again after a sidebar click joins with the mic', (
    tester,
  ) async {
    final rig = await _open(tester, pageLoad: false);
    await _untilJoinFailed(tester, rig);
    expect(rig.session.micAtJoin, isEmpty, reason: 'the first token failed');

    await _retry(tester, rig);
    expect(rig.session.micAtJoin, [true]);
  });
}
