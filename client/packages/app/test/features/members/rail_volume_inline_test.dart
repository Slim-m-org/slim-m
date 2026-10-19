// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The people under a voice channel in the rail open their member card and a
/// menu without the viewer joining the call (owner backlog 221).
library;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_voice_participants.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
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

void main() {
  testWidgets(
    'one right click shows the volume slider, which the keyboard moves',
    (tester) async {
      await _pump(tester, permissions: 0);
      await rightClickMenu(tester, find.text('Bob'));
      expect(find.byType(AppSlider), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      final percent = find.textContaining('%');
      expect(percent, findsOneWidget);
      expect(tester.widget<Text>(percent).data, isNot('100%'));
      expect(
        find.byType(AppSlider),
        findsOneWidget,
        reason: 'the menu stays open',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AppSlider), findsNothing);
    },
  );
}
