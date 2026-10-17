// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member card a call tile opens has to anchor to the tile that was
/// tapped, the way a popover normally does - reported directly by the owner
/// from a screenshot with an arrow drawn from a bottom filmstrip tile all
/// the way across the window to a card pinned in the top-right corner.
///
/// `CallStageLayout` used to build every tile's tap handler as `() =>
/// onOpenProfile(participant)`, a closure bound to `_InCall`'s own outer
/// `BuildContext` rather than the tile's - so every tile, wherever it sat on
/// screen, opened its card anchored to that one shared, unrelated box. The
/// assertion here reads the popover's real rendered `Rect` against the
/// tapped tile's own, not just that a popover exists: a presence-only check
/// would have passed on the bug as readily as it passes on the fix.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
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

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    "tapping a remote participant's tile in the bottom filmstrip opens the "
    'member card anchored beside that tile, not the top of the window',
    (tester) async {
      const window = Size(1400, 900);
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
          membersProvider.overrideWith((ref) async => [_bobProfile]),
          myPermissionsProvider.overrideWithValue(0),
          // Presence otherwise brings up the real live-socket machinery, which never settles under pumpAndSettle.
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

      // Pre-warms the autoDispose future so the tap below finds a resolved profile rather than racing one.
      await harness.container.read(membersProvider.future);

      final tapTarget = find.byKey(const ValueKey('film-user-bob'));
      expect(
        tapTarget,
        findsOneWidget,
        reason: 'Bob sits in the bottom filmstrip beside the shared stage',
      );
      // The real anchor showMemberProfile measures from, not the filmstrip's outer Center wrapper.
      final tileRect = tester.getRect(
        find.ancestor(
          of: find.text('Bob'),
          matching: find.byType(CallParticipantTile),
        ),
      );
      // The filmstrip sits low in the window, matching the report's "tiles along the bottom" framing.
      expect(tileRect.top, greaterThan(window.height / 2));

      await tester.tap(tapTarget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(AppMenu), findsOneWidget);
      final popoverRect = tester.getRect(find.byType(AppMenu));

      // Flush with the anchor's own top (fits below) or bottom (flips above) - either way, on the tapped tile's own edge.
      final flushBelow = (popoverRect.top - tileRect.top).abs() < 1;
      final flushAbove = (popoverRect.bottom - tileRect.bottom).abs() < 1;
      expect(
        flushBelow || flushAbove,
        isTrue,
        reason:
            'the popover should be flush with the tapped tile - top '
            '${popoverRect.top} vs tile top ${tileRect.top}, or popover '
            'bottom ${popoverRect.bottom} vs tile bottom ${tileRect.bottom} - '
            'not positioned by whatever box the outer, unrelated `_InCall` '
            'context happens to resolve to',
      );

      await harness.container.read(voiceControllerProvider.notifier).leave();
    },
  );

  testWidgets(
    "Moderate... from a tile's quick-actions menu opens the moderation view "
    'anchored beside that tile',
    (tester) async {
      const window = Size(1400, 900);
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
          membersProvider.overrideWith((ref) async => [_bobProfile]),
          myPermissionsProvider.overrideWithValue(Perm.kickMembers),
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

      final tile = find.ancestor(
        of: find.text('Bob'),
        matching: find.byType(CallParticipantTile),
      );
      final tileRect = tester.getRect(tile);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('film-user-bob'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pumpAndSettle();
      // Nothing in this harness holds membersProvider; the call view must.
      expect(find.text('View profile'), findsOneWidget);
      expect(find.text('Moderate...'), findsOneWidget);
      await tester.tap(find.text('Moderate...'));
      await tester.pumpAndSettle();

      expect(find.byType(AppMenu), findsOneWidget, reason: 'the profile card');
      final popoverRect = tester.getRect(find.byType(AppMenu));
      final flushTop = (popoverRect.top - tileRect.top).abs() < 1;
      final flushBottom = (popoverRect.bottom - tileRect.bottom).abs() < 1;
      expect(
        flushTop || flushBottom,
        isTrue,
        reason:
            'moderation view at top ${popoverRect.top}/bottom '
            '${popoverRect.bottom} vs tile ${tileRect.top}/${tileRect.bottom} '
            '- it must anchor to the tile the menu was opened from',
      );
      await harness.container.read(voiceControllerProvider.notifier).leave();
    },
  );
}
