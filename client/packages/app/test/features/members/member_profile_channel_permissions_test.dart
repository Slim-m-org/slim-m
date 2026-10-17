// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves the split docs/decisions/0011-per-channel-permissions.md draws
/// through `member_profile.dart`'s own moderation section: `canEject` reads
/// the call's own channel, its three siblings (time out, remove, roles)
/// read the caller's deployment-wide base set, and the two can disagree.
///
/// Each half is its own test rather than one asserting both bits at once, so
/// a wrongly-converted sibling and a not-converted `canEject` fail on
/// different tests and neither hides the other.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/reduced_motion_harness.dart';
import '../../voice_controller_harness.dart' show FakeSession, tokens;

const _channelId = 'channel-shared';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

/// [basePermissions] answers `/me`; [channelPermissions] answers
/// `GET /channels/$_channelId/permissions` - the two figures this test
/// exists to prove stay independent.
({ProviderContainer container, FakeSession session}) _wire({
  required int basePermissions,
  required int channelPermissions,
}) {
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      myPermissionsProvider.overrideWithValue(basePermissions),
      membersProvider.overrideWith((ref) async => [_other]),
      rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/voice/token')) {
              return http.Response(
                jsonEncode({
                  'url': 'wss://sfu.example.com',
                  'room': _channelId,
                  'token': 'jwt',
                  'expires_at': 0,
                  'can_publish': true,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/channels/$_channelId/permissions') {
              return http.Response(
                jsonEncode({'permissions': channelPermissions}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, session: session);
}

Future<void> _joinShared(
  WidgetTester tester,
  ProviderContainer container,
  FakeSession session,
) async {
  await container.read(voiceControllerProvider.notifier).join(_channelId);
  session.emitState(VoiceSessionState.connected);
  session.emitParticipants([
    VoiceParticipant(
      identity: _other.id,
      name: _other.displayName,
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
    ),
  ]);
  await tester.pump();
  // A second pump for channelPermissionsProvider's own mocked round trip.
  await tester.pump();
}

/// The default test window (800x600) is shorter than the call section plus
/// the moderation section plus the private-note row plus the off-hours
/// notification row can fit without scrolling; a real desktop window is
/// taller, and `AnchoredMemberPopover` clamps and scrolls its own content,
/// so this is a test-harness fix rather than production behavior changing.
/// `_harness` pumps `MemberProfileBody` directly, bypassing that popover, so
/// it needs the room itself.
void _giveDesktopMenuRoom(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _harness(ProviderContainer container) => reducedMotionApp(
  container: container,
  child: MemberProfileBody(profile: _other, compact: false, onDone: () {}),
);

void main() {
  testWidgets(
    'a channel overwrite alone is enough for eject, with no base bit at all',
    (tester) async {
      _giveDesktopMenuRoom(tester);
      final wired = _wire(
        basePermissions: 0,
        channelPermissions: Perm.kickMembers,
      );
      await tester.pumpWidget(_harness(wired.container));
      await _joinShared(tester, wired.container, wired.session);
      await tester.tap(find.text('Moderate...'));
      await tester.pumpAndSettle();

      expect(find.text('Eject from call...'), findsOneWidget);
      // Base grants nothing, so the deployment-wide siblings stay absent.
      expect(find.text('Time out for...'), findsNothing);
      expect(find.text('Remove from Space...'), findsNothing);
      await wired.container.read(voiceControllerProvider.notifier).leave();
    },
  );

  testWidgets(
    'the base bit alone offers the deployment-wide siblings but not eject, '
    'when this channel denies it',
    (tester) async {
      _giveDesktopMenuRoom(tester);
      final wired = _wire(
        basePermissions: Perm.kickMembers | Perm.banMembers,
        channelPermissions: 0,
      );
      await tester.pumpWidget(_harness(wired.container));
      await _joinShared(tester, wired.container, wired.session);
      await tester.tap(find.text('Moderate...'));
      await tester.pumpAndSettle();

      // Base holds it, so both deployment-wide actions render.
      expect(find.text('Time out for...'), findsOneWidget);
      expect(find.text('Remove from Space...'), findsOneWidget);
      // This channel's own answer denies it, so eject alone is absent.
      expect(find.text('Eject from call...'), findsNothing);
      await wired.container.read(voiceControllerProvider.notifier).leave();
    },
  );
}
