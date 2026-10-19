// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail row and the lounge tile open the same menu for one person in every
/// state they can be in: camera, share, both, muted, a hidden share and yourself.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/rail_voice_participants.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_call_menu.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_api.dart';
import '../../support/menu_gestures.dart';
import 'voice_controller_harness.dart' show FixedVoiceController;

const _profile = api.UserProfile(
  id: 'user-bob',
  username: 'bob',
  displayName: 'Bob',
  createdAt: 0,
);

const _tokens = api.TokenPair(
  userId: 'user-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

VoiceParticipant _bob({
  bool muted = false,
  bool camera = false,
  bool share = false,
  bool local = false,
}) => VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isLocal: local,
  isSpeaking: false,
  isMuted: muted,
  isScreenSharing: share,
  isCameraOn: camera,
);

List<String> _labels(WidgetTester tester) => [
  for (final i in tester.widgetList<AppMenuItem>(find.byType(AppMenuItem)))
    i.label,
];

Future<({List<String> rail, List<String> lounge})> _menus(
  WidgetTester tester,
  VoiceParticipant bob, {
  bool hidden = false,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((_) async => http.Response('{}', 404)),
      userProfileProvider('user-bob').overrideWith((ref) async => _profile),
      membersProvider.overrideWith((ref) async => [_profile]),
      myPermissionsProvider.overrideWithValue(Perm.kickMembers),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(
          ref,
          VoiceState(
            channelId: 'voice-1',
            state: VoiceSessionState.connected,
            participants: [bob],
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  if (hidden) container.read(shareWatchProvider.notifier).stop('user-bob');
  await container.read(membersProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 240,
                child: RailParticipantList(
                  participants: [bob],
                  channelId: 'voice-1',
                ),
              ),
              Consumer(
                // The call screen holds the roster for as long as it shows tiles.
                builder: (context, ref, _) {
                  ref.watch(membersProvider);
                  return CallParticipantTile(
                    participant: bob,
                    contextMenuItemsBuilder: (menuContext, close) =>
                        participantCallMenuItems(
                          menuContext,
                          ref,
                          participant: bob,
                          close: close,
                        ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await rightClickMenu(tester, find.text('Bob').first);
  final rail = _labels(tester);
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
  await rightClickMenu(tester, find.byType(CallParticipantTile));
  return (rail: rail, lounge: _labels(tester));
}

void main() {
  final states = <String, (VoiceParticipant, {bool hidden})>{
    'plain': (_bob(), hidden: false),
    'muted': (_bob(muted: true), hidden: false),
    'camera': (_bob(camera: true), hidden: false),
    'share': (_bob(share: true), hidden: false),
    'camera and share': (_bob(camera: true, share: true), hidden: false),
    'a hidden share': (_bob(share: true), hidden: true),
    'yourself sharing': (_bob(local: true, share: true), hidden: false),
    'yourself on camera': (_bob(local: true, camera: true), hidden: false),
  };
  for (final entry in states.entries) {
    testWidgets('rail and lounge menus match for ${entry.key}', (tester) async {
      final (bob, :hidden) = entry.value;
      final menus = await _menus(tester, bob, hidden: hidden);
      expect(menus.rail, isNotEmpty, reason: 'the rail row opens a menu');
      expect(menus.lounge, menus.rail);
    });
  }
}
