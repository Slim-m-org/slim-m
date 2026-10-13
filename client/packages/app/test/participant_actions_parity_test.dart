// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The left-click profile card and the right-click menu offer one list.
///
/// Both render from `participantActions`, so this drives each surface for the
/// same shared-call participant and checks every action in the shared list is
/// on screen where it is meant to be, and nothing call-related is on screen
/// that the list does not name. Also covers per-person volume reaching the
/// session and surviving a restart.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_app/src/widgets/participant_actions.dart';
import 'package:slimm_app/src/widgets/participant_call_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/reduced_motion_harness.dart';
import 'voice_controller_harness.dart' show FakeSession, tokens;

const _channelId = 'channel-shared';

const _bot = api.UserProfile(
  id: 'user-bot',
  username: 'jellyfin',
  displayName: 'jellyfin',
  isBot: true,
  createdAt: 0,
);

const _participant = VoiceParticipant(
  identity: 'user-bot',
  name: 'jellyfin',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

({ProviderContainer container, FakeSession session}) _wire({
  int permissions = 0,
}) {
  final session = FakeSession();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      myPermissionsProvider.overrideWithValue(permissions),
      syncControllerProvider.overrideWith(_NoopSyncController.new),
      membersProvider.overrideWith((ref) async => [_bot]),
      rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            final json = {'content-type': 'application/json'};
            if (request.url.path.endsWith('/voice/token')) {
              final body = {
                'url': 'wss://sfu.example.com',
                'room': _channelId,
                'token': 'jwt',
                'expires_at': 0,
                'can_publish': true,
              };
              return http.Response(jsonEncode(body), 200, headers: json);
            }
            if (request.url.path.endsWith('/note')) {
              final body = {'body': null, 'updated_at': null};
              return http.Response(jsonEncode(body), 200, headers: json);
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
  session.emitParticipants([_participant]);
  await tester.pump();
  await tester.pump();
}

void _roomy(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _card(ProviderContainer container) => reducedMotionApp(
  container: container,
  child: SingleChildScrollView(
    child: MemberProfileBody(profile: _bot, compact: false, onDone: () {}),
  ),
);

Widget _menu(ProviderContainer container) => reducedMotionApp(
  container: container,
  child: Consumer(
    builder: (context, ref, _) => AppMenu(
      width: 240,
      children: participantCallMenuItems(
        context,
        ref,
        participant: _participant,
        close: () {},
      ),
    ),
  ),
);

const _labels = <ParticipantAction, Map<ParticipantSurface, String>>{
  ParticipantAction.volume: {
    ParticipantSurface.card: 'Volume for you',
    ParticipantSurface.menu: 'Volume...',
  },
  ParticipantAction.muteForMe: {
    ParticipantSurface.card: 'Mute for me',
    ParticipantSurface.menu: 'Mute for me',
  },
  ParticipantAction.message: {
    ParticipantSurface.card: 'Message',
    ParticipantSurface.menu: 'Message',
  },
  ParticipantAction.viewProfile: {ParticipantSurface.menu: 'View profile'},
  ParticipantAction.moderate: {
    ParticipantSurface.card: 'Moderate...',
    ParticipantSurface.menu: 'Moderate...',
  },
};

void _expectSurfaceMatchesList(
  ParticipantSurface surface,
  List<ParticipantAction> expected,
) {
  for (final action in ParticipantAction.values) {
    final label = _labels[action]![surface];
    if (label == null) continue;
    expect(
      find.text(label),
      expected.contains(action) ? findsOneWidget : findsNothing,
      reason: '$action on the $surface',
    );
  }
}

List<ParticipantAction> _listFor(ParticipantSurface surface, int permissions) =>
    participantActions(
      surface: surface,
      isSelf: false,
      inCallTogether: true,
      supportsVolume: true,
      hasProfile: true,
      showModeration: permissions != 0,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final permissions in [0, Perm.kickMembers]) {
    testWidgets('card and menu both offer the shared list, permissions '
        '$permissions', (tester) async {
      _roomy(tester);
      final wired = _wire(permissions: permissions);
      await wired.container.read(membersProvider.future);

      await tester.pumpWidget(_card(wired.container));
      await _joinShared(tester, wired.container, wired.session);
      _expectSurfaceMatchesList(
        ParticipantSurface.card,
        _listFor(ParticipantSurface.card, permissions),
      );

      await tester.pumpWidget(_menu(wired.container));
      await tester.pumpAndSettle();
      _expectSurfaceMatchesList(
        ParticipantSurface.menu,
        _listFor(ParticipantSurface.menu, permissions),
      );

      final shared = [
        ParticipantAction.volume,
        ParticipantAction.muteForMe,
        ParticipantAction.message,
        if (permissions != 0) ParticipantAction.moderate,
      ];
      for (final action in shared) {
        expect(
          _listFor(ParticipantSurface.card, permissions),
          contains(action),
        );
        expect(
          _listFor(ParticipantSurface.menu, permissions),
          contains(action),
        );
      }
      await wired.container.read(voiceControllerProvider.notifier).leave();
    });
  }

  test('no action is offered against yourself', () {
    final list = participantActions(
      surface: ParticipantSurface.menu,
      isSelf: true,
      inCallTogether: true,
      supportsVolume: true,
      hasProfile: true,
      showModeration: true,
    );
    expect(list, isEmpty);
  });

  testWidgets('volume reaches the session for that participant and is saved', (
    tester,
  ) async {
    final wired = _wire();
    final controller = wired.container.read(voiceControllerProvider.notifier);

    await controller.setVolumeFor('user-bot', 1.5);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(wired.session.volumeFor('user-bot'), 1.5);
    expect(wired.session.volumeFor('user-other'), 1.0);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      prefs.getString('slimm.voice.participant_volumes')!,
    );
    expect(saved, {'user-bot': 1.5});

    await controller.setVolumeFor('user-bot', 1.0);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(
      jsonDecode(prefs.getString('slimm.voice.participant_volumes')!),
      isEmpty,
      reason: 'back at the default, the entry goes away',
    );
  });

  testWidgets('a saved volume is applied to the session on restore', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.participant_volumes': jsonEncode({'user-bot': 0.3}),
    });
    final wired = _wire();

    await tester.runAsync(
      wired.container
          .read(voiceControllerProvider.notifier)
          .restoreParticipantVolumes,
    );

    expect(wired.session.volumeFor('user-bot'), 0.3);
  });
}
