// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Signing out never left a live call. `voiceControllerProvider` is
/// app-lifetime, not scoped to a session, so nothing else would ever stop it
/// posting a heartbeat against a session `SignOutRow.signOut` was about to
/// clear, each 401 swallowed silently for the rest of the process's life.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_account_sections.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';
import 'support/fake_sync.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// `PushController`'s own constructor fires an unawaited `register()` the
/// instant a signed-in session exists, which reaches real APNs/FCM platform
/// channels this test has no host for; overriding it the same way keeps
/// construction safe while `unregister()`, the method under test, stays real.
class _NoopPushController extends PushController {
  _NoopPushController(super.ref);

  @override
  Future<void> register() async {}
}

void main() {
  testWidgets('signing out mid-call leaves the call rather than stranding its '
      'heartbeat against a session about to be cleared', (tester) async {
    final session = FakeSession();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        pushControllerProvider.overrideWith((ref) => _NoopPushController(ref)),
        // Sign-out clears the local store; that failure is already swallowed.
        storeProvider.overrideWith((ref) async => throw StateError('n/a')),
        mockApiOverride((request) async {
          if (request.url.path.endsWith('/voice/token')) {
            return http.Response(
              jsonEncode({
                'url': 'wss://sfu.example.com',
                'room': 'channel-1',
                'token': 'jwt',
                'expires_at': 0,
                'can_publish': true,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path.endsWith('/voice/heartbeat')) {
            return http.Response('', 204);
          }
          if (request.url.path == '/auth/logout') {
            return http.Response('', 204);
          }
          return http.Response('', 404);
        }),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(voiceControllerProvider.notifier);
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    expect(session.leaveCalls, 0, reason: 'sanity: really joined first');

    late WidgetRef ref;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await SignOutRow.signOut(ref);

    expect(
      session.leaveCalls,
      1,
      reason:
          'signing out mid-call must leave it, not just clear the '
          'session out from under a heartbeat timer left running',
    );
    expect(
      container.read(voiceControllerProvider).state,
      VoiceSessionState.idle,
    );
  });
}
