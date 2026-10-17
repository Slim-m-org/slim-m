// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `participantCallMenuItems` - the rows a right-click or long-press on a
/// call participant offers, shared by the call view and the canvas bubble.
///
/// This device's own tile gets nothing; a remote one gets mute for me
/// always, volume when the platform supports it, view profile when the
/// member list actually has a profile for them, and moderate only when
/// `memberModerationGates` says the viewer is permitted - the same gating
/// `member_profile_channel_permissions_test.dart` already proves for the
/// full member card, reused rather than re-derived here.
library;

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
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_call_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/reduced_motion_harness.dart';
import 'voice_controller_harness.dart' show FakeSession, tokens;
import 'support/fake_sync.dart';

const _maya = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

const _remote = VoiceParticipant(
  identity: 'user-maya',
  name: 'maya',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _local = VoiceParticipant(
  identity: 'user-me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

({ProviderContainer container, FakeSession session}) _wire({
  int permissions = 0,
  List<api.UserProfile> members = const [_maya],
}) {
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      myPermissionsProvider.overrideWithValue(permissions),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      membersProvider.overrideWith((ref) async => members),
      rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
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

/// Renders [participantCallMenuItems]'s own output directly, in an
/// [AppMenu] the same way every caller of it does.
Widget _harness(
  ProviderContainer container,
  VoiceParticipant participant, {
  VoidCallback? onClose,
}) => reducedMotionApp(
  container: container,
  child: Consumer(
    builder: (context, ref, _) => AppMenu(
      width: 240,
      children: participantCallMenuItems(
        context,
        ref,
        participant: participant,
        close: onClose ?? () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('this device\'s own tile gets no rows at all', (tester) async {
    final wired = _wire();
    await tester.pumpWidget(_harness(wired.container, _local));

    expect(find.byType(AppMenuItem), findsNothing);
  });

  testWidgets('a remote participant always gets mute for me', (tester) async {
    final wired = _wire();
    await tester.pumpWidget(_harness(wired.container, _remote));

    expect(find.text('Mute for me'), findsOneWidget);
  });

  testWidgets(
    'mute for me toggles the controller and closes the menu, unmute for me '
    'afterward',
    (tester) async {
      var closed = 0;
      final wired = _wire();
      await tester.pumpWidget(
        _harness(wired.container, _remote, onClose: () => closed++),
      );
      final controller = wired.container.read(voiceControllerProvider.notifier);
      expect(controller.isLocallyMuted(_remote.identity), isFalse);

      await tester.tap(find.text('Mute for me'));
      await tester.pump();

      expect(controller.isLocallyMuted(_remote.identity), isTrue);
      expect(closed, 1);
    },
  );

  testWidgets(
    'volume is offered on a platform that supports it - FakeSession answers '
    'true - and opens a popover naming the participant',
    (tester) async {
      final wired = _wire();
      await tester.pumpWidget(_harness(wired.container, _remote));

      expect(find.text('Volume...'), findsOneWidget);

      await tester.tap(find.text('Volume...'));
      await tester.pumpAndSettle();

      expect(find.text('Volume for maya'), findsOneWidget);
    },
  );

  testWidgets('view profile is absent without a matching member', (
    tester,
  ) async {
    final noProfile = _wire(members: const []);
    // Pre-resolved: participantCallMenuItems reads membersProvider, never watches it, since it runs inside an onTap closure, not a build.
    await noProfile.container.read(membersProvider.future);
    await tester.pumpWidget(_harness(noProfile.container, _remote));
    await tester.pumpAndSettle();

    expect(find.text('View profile'), findsNothing);
  });

  testWidgets(
    'view profile is present once a matching member exists, and opens the '
    'real profile',
    (tester) async {
      final wired = _wire();
      await wired.container.read(membersProvider.future);
      await tester.pumpWidget(_harness(wired.container, _remote));
      await tester.pumpAndSettle();
      expect(find.text('View profile'), findsOneWidget);

      await tester.tap(find.text('View profile'));
      await tester.pumpAndSettle();

      expect(find.text('@maya'), findsOneWidget);
    },
  );

  testWidgets('moderate is absent with no moderation right', (tester) async {
    final none = _wire(permissions: 0);
    await none.container.read(membersProvider.future);
    await tester.pumpWidget(_harness(none.container, _remote));
    await tester.pumpAndSettle();

    expect(find.text('Moderate...'), findsNothing);
  });

  testWidgets('moderate is present once a moderation right exists, and reaches '
      'straight into the moderate view rather than the profile it would '
      'otherwise be one tap behind', (tester) async {
    final permitted = _wire(permissions: Perm.kickMembers);
    await permitted.container.read(membersProvider.future);
    await tester.pumpWidget(_harness(permitted.container, _remote));
    await tester.pumpAndSettle();
    expect(find.text('Moderate...'), findsOneWidget);

    await tester.tap(find.text('Moderate...'));
    await tester.pumpAndSettle();

    expect(find.text('Time out for...'), findsOneWidget);
  });
}
