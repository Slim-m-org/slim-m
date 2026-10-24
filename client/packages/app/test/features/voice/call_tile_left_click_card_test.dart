// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A left click on a call tile opens a profile-only card on a wide layout,
/// where right click reaches the actions, and the full card on a narrow one.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);

const _bob = VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
  isCameraOn: false,
);

const _bobProfile = api.UserProfile(
  id: 'user-bob',
  username: 'bob',
  displayName: 'Bob',
  createdAt: 0,
);

const _meProfile = api.UserProfile(
  id: 'user-1',
  username: 'me',
  displayName: 'Me',
  createdAt: 0,
);

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

Future<VoiceHarness> _open(WidgetTester tester, Size window) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      voiceRosterProvider.overrideWith(
        (ref, channelId) =>
            const Stream<List<api.VoiceRosterParticipant>>.empty(),
      ),
      membersProvider.overrideWith((ref) async => [_bobProfile, _meProfile]),
      myPermissionsProvider.overrideWithValue(0),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
    ],
  );
  addTearDown(harness.dispose);
  await tester.pumpWidget(
    _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants(const [_me, _bob]);
  await tester.pump();
  await tester.pumpAndSettle();
  await harness.container.read(membersProvider.future);
  return harness;
}

Finder _tile(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byType(CallParticipantTile),
);

Future<void> _leftClick(WidgetTester tester, Finder tile) async {
  await tester.tap(tile.first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('wide: left click shows the profile without the action rows', (
    tester,
  ) async {
    final harness = await _open(tester, const Size(1400, 900));
    await _leftClick(tester, _tile('Bob'));
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Report user'), findsNothing);
    expect(find.text('Notify me off hours'), findsNothing);
    expect(find.text('Block'), findsNothing);
    await harness.container.read(voiceControllerProvider.notifier).leave();
  });

  testWidgets('wide: right click still opens the quick menu', (tester) async {
    final harness = await _open(tester, const Size(1400, 900));
    final gesture = await tester.startGesture(
      tester.getCenter(_tile('Bob').first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('View profile'), findsOneWidget);
    await harness.container.read(voiceControllerProvider.notifier).leave();
  });

  testWidgets('narrow: left click keeps the action rows', (tester) async {
    final harness = await _open(tester, const Size(420, 900));
    await _leftClick(tester, _tile('Bob'));
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Report user'), findsOneWidget);
    await harness.container.read(voiceControllerProvider.notifier).leave();
  });

  testWidgets('your own tile does nothing on a left click', (tester) async {
    final harness = await _open(tester, const Size(1400, 900));
    await _leftClick(tester, _tile('Me'));
    expect(find.text('Message'), findsNothing);
    expect(find.byType(AppMenu), findsNothing);
    await harness.container.read(voiceControllerProvider.notifier).leave();
  });
}
