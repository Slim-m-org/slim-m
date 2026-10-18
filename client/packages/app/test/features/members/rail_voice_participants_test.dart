// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The people under a voice channel in the rail open their member card and a
/// menu without the viewer joining the call (owner backlog 221).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_voice_participants.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/participant_call_menu.dart';
import '../../support/fake_api.dart';
import '../../support/menu_gestures.dart';
import '../voice/voice_controller_harness.dart' show FakeSession;

const _bob = VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _bobProfile = api.UserProfile(
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

Future<void> _pump(
  WidgetTester tester, {
  required int permissions,
  Size size = const Size(1280, 800),
  VoiceParticipant participant = _bob,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((_) async => http.Response('{}', 404)),
        userProfileProvider(
          'user-bob',
        ).overrideWith((ref) async => _bobProfile),
        membersProvider.overrideWith((ref) async => [_bobProfile]),
        myPermissionsProvider.overrideWithValue(permissions),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: FakeSession()),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: RailParticipantList(
              participants: [participant],
              channelId: 'voice-1',
            ),
          ),
        ),
      ),
    ),
  );
  // The speaking ring animates forever, so a speaking participant never settles.
  if (participant.isSpeaking) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'clicking a participant opens their member card without joining',
    (tester) async {
      await _pump(tester, permissions: 0);
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.byType(MemberProfileBody), findsOneWidget);
    },
  );

  testWidgets('a moderator gets Moderate in the menu, a member does not', (
    tester,
  ) async {
    await _pump(tester, permissions: Perm.kickMembers);
    await _rightClick(tester, find.text('Bob'));
    expect(find.text('View profile'), findsOneWidget);
    expect(find.text('Moderate...'), findsOneWidget);
  });

  testWidgets('a plain member sees View profile only', (tester) async {
    await _pump(tester, permissions: 0);
    await _rightClick(tester, find.text('Bob'));
    expect(find.text('View profile'), findsOneWidget);
    expect(find.text('Moderate...'), findsNothing);
  });

  testWidgets('on a phone a participant row is a full touch target', (
    tester,
  ) async {
    await _pump(tester, permissions: 0, size: const Size(390, 844));
    final row = find
        .ancestor(of: find.text('Bob'), matching: find.byType(GestureDetector))
        .first;
    expect(tester.getSize(row).height, greaterThanOrEqualTo(AppSizes.rowTouch));
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberProfileBody), findsOneWidget);
  });

  testWidgets('a speaking participant still reads as speaking', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      permissions: 0,
      participant: const VoiceParticipant(
        identity: 'user-bob',
        name: 'Bob',
        isLocal: false,
        isSpeaking: true,
        isMuted: false,
        isScreenSharing: false,
      ),
    );
    // The e2e harness matches a node's label by substring, as here.
    expect(find.bySemanticsLabel(RegExp('Bob, speaking')), findsOneWidget);
    semantics.dispose();
  });

  const quickActions = [
    'Volume...',
    'Mute for me',
    'Message',
    'View profile',
    'Moderate...',
  ];

  List<String> openLabels(WidgetTester tester) => [
    for (final item in tester.widgetList<AppMenuItem>(find.byType(AppMenuItem)))
      item.label,
  ];

  for (final (how, open) in <(String, Future<void> Function(WidgetTester))>[
    ('right-click', (t) => rightClickMenu(t, find.text('Bob'))),
    ('long-press', (t) => longPressMenu(t, find.text('Bob'))),
  ]) {
    testWidgets('a rail row offers the lounge actions on $how', (tester) async {
      await _pump(tester, permissions: Perm.kickMembers);
      await open(tester);
      expect(openLabels(tester), quickActions);
    });
  }

  testWidgets('the context-menu key opens the rail row menu', (tester) async {
    await _pump(tester, permissions: Perm.kickMembers);
    await keyboardMenu(tester);
    expect(openLabels(tester), quickActions);
  });

  testWidgets('the rail menu and the lounge tile menu list the same items', (
    tester,
  ) async {
    await _pump(tester, permissions: Perm.kickMembers);
    await rightClickMenu(tester, find.text('Bob'));
    final rail = openLabels(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          mockApiOverride((_) async => http.Response('{}', 404)),
          membersProvider.overrideWith((ref) async => [_bobProfile]),
          myPermissionsProvider.overrideWithValue(Perm.kickMembers),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: FakeSession()),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  ref.watch(membersProvider);
                  return CallParticipantTile(
                    participant: _bob,
                    contextMenuItemsBuilder: (menuContext, close) =>
                        participantCallMenuItems(
                          menuContext,
                          ref,
                          participant: _bob,
                          close: close,
                        ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await ProviderScope.containerOf(
      tester.element(find.byType(CallParticipantTile)),
    ).read(membersProvider.future);
    await rightClickMenu(tester, find.byType(CallParticipantTile));
    expect(openLabels(tester), rail);
  });
}
