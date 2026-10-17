// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stage-and-filmstrip layout `call_stage_layout.dart` replaced three
/// separate boxes with. The owner's own report: "it creates 3 different
/// boxes for if I'm screen sharing and having my camera on and it's not
/// very easy to navigate on mobile or vertical views."
///
/// Covers what a participant is on this screen now (one tile, plus a stage
/// tile only while they are actually sharing, never a second camera box),
/// what decides the stage (a live share always wins it, local or remote),
/// and that the layout survives a tall, narrow viewport - the shape the
/// owner reported as unusable - without overflowing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/call_roster_motion.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _me = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _meSharing = VoiceParticipant(
  identity: 'user-1',
  name: 'Me',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);

const _aliceSharingWithCameraOn = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
  isCameraOn: true,
);

const _aliceSharing = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);

const _aliceOnCameraOnly = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _bobOnCameraOnly = VoiceParticipant(
  identity: 'user-3',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _bobSharing = VoiceParticipant(
  identity: 'user-3',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
  isCameraOn: true,
);

Widget _harness(Widget child, ProviderContainer container) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

/// Joins, connects and seats [participants] on a view of [size] - the shared
/// starting point every test here drives further.
Future<VoiceHarness> _connected(
  WidgetTester tester,
  List<VoiceParticipant> participants, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(
    session,
    voiceApi(),
    extraOverrides: [
      voiceRosterProvider.overrideWith(
        (ref, channelId) => const Stream<List<VoiceRosterParticipant>>.empty(),
      ),
    ],
  );

  await tester.pumpWidget(
    _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants(participants);
  await tester.pump();
  await tester.pumpAndSettle();

  return harness;
}

/// Every test that connects a call leaves it before the widget tree is torn
/// down, in the test body itself: `sign_out_leaves_call_test.dart` already
/// documents why this cannot move into `addTearDown` (the pending-timer
/// check for the heartbeat `connected` starts runs before any teardown).
Future<void> _leave(VoiceHarness harness) =>
    harness.container.read(voiceControllerProvider.notifier).leave();

void main() {
  testWidgets(
    'sharing with the camera on is one stage tile plus one filmstrip tile - '
    'never a second box for the same camera',
    (tester) async {
      final harness = await _connected(tester, const [
        _me,
        _aliceSharingWithCameraOn,
      ]);
      addTearDown(harness.dispose);

      expect(
        find.byType(ScreenShareStage),
        findsOneWidget,
        reason: 'exactly one stage, for the one live share',
      );
      expect(
        find.byKey(const Key('fake-share-view-user-2')),
        findsOneWidget,
        reason: "Alice's screen is the stage content",
      );
      expect(
        find.byKey(const Key('fake-camera-view-user-2')),
        findsOneWidget,
        reason:
            "Alice's camera renders once, inside her own filmstrip tile - "
            'not a second box beside the stage',
      );
      expect(
        find.byType(CallParticipantTile),
        findsNWidgets(2),
        reason: 'one tile per participant, sharer included',
      );

      await _leave(harness);
    },
  );

  testWidgets('nobody sharing means no stage at all, just the tile grid', (
    tester,
  ) async {
    final harness = await _connected(tester, const [_me, _aliceOnCameraOnly]);
    addTearDown(harness.dispose);

    expect(find.byType(ScreenShareStage), findsNothing);
    expect(find.byType(CallParticipantTile), findsNWidgets(2));
    expect(find.byKey(const Key('fake-camera-view-user-2')), findsOneWidget);

    await _leave(harness);
  });

  testWidgets(
    'a local participant sharing alone still stages their own screen',
    (tester) async {
      final harness = await _connected(tester, const [_meSharing]);
      addTearDown(harness.dispose);

      expect(find.byType(ScreenShareStage), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-user-1')), findsOneWidget);

      await _leave(harness);
    },
  );

  testWidgets(
    'a remote sharer takes the stage over a local participant sharing at '
    'the same time, local listed first',
    (tester) async {
      final harness = await _connected(tester, const [
        _meSharing,
        _aliceSharing,
      ]);
      addTearDown(harness.dispose);

      expect(find.byType(ScreenShareStage), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-user-2')), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-user-1')), findsNothing);

      await _leave(harness);
    },
  );

  testWidgets(
    'a remote sharer takes the stage over a local participant sharing at '
    'the same time, remote listed first - the order a "last sharer found '
    'wins" bug would get right by accident',
    (tester) async {
      final harness = await _connected(tester, const [
        _aliceSharing,
        _meSharing,
      ]);
      addTearDown(harness.dispose);

      expect(find.byType(ScreenShareStage), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-user-2')), findsOneWidget);
      expect(find.byKey(const Key('fake-share-view-user-1')), findsNothing);

      await _leave(harness);
    },
  );

  testWidgets(
    'a hand-off between two live sharers keeps the filmstrip mounted rather '
    'than fading every tile in it from blank',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
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
                const Stream<List<VoiceRosterParticipant>>.empty(),
          ),
        ],
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await tester.pump();
      session.emitParticipants(const [_aliceSharing, _bobOnCameraOnly]);
      await tester.pump();
      await tester.pumpAndSettle();

      final bobTileOpacity = find.ancestor(
        of: find.byKey(const Key('fake-camera-view-user-3')),
        matching: find.byType(Opacity),
      );

      // Alice stops, Bob starts: a stage exists throughout, so Bob's own tile must never go dark.
      session.emitParticipants(const [
        VoiceParticipant(
          identity: 'user-2',
          name: 'Alice',
          isLocal: false,
          isSpeaking: false,
          isMuted: false,
          isScreenSharing: false,
        ),
        _bobSharing,
      ]);
      await tester.pump();
      await tester.pump();

      expect(
        tester.widget<Opacity>(bobTileOpacity.first).opacity,
        1.0,
        reason:
            'the stage-to-stage hand-off must update in place, not remount '
            'the whole filmstrip',
      );

      await _leave(harness);
    },
  );

  testWidgets(
    'a share appearing where there was none still fades in, since that is '
    'genuinely new content rather than a hand-off',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
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
                const Stream<List<VoiceRosterParticipant>>.empty(),
          ),
        ],
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _harness(const VoiceScreen(channelId: 'channel-1'), harness.container),
      );
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await tester.pump();
      session.emitParticipants(const [_me, _aliceOnCameraOnly]);
      await tester.pump();
      await tester.pumpAndSettle();

      session.emitParticipants(const [_me, _aliceSharingWithCameraOn]);
      await tester.pump();
      await tester.pump();

      final stageOpacity = find.ancestor(
        of: find.byType(ScreenShareStage),
        matching: find.byType(Opacity),
      );
      expect(
        tester.widget<Opacity>(stageOpacity.first).opacity,
        lessThan(1.0),
        reason:
            'a stage appearing where there was only a grid is real new '
            'content, and still deserves its entrance fade',
      );

      await _leave(harness);
    },
  );

  testWidgets(
    'a share with a camera on and a second camera participant fits a tall, '
    'narrow phone with no overflow',
    (tester) async {
      final harness = await _connected(tester, const [
        _me,
        _aliceSharingWithCameraOn,
        _bobOnCameraOnly,
      ]);
      addTearDown(harness.dispose);

      expect(tester.takeException(), isNull);

      await _leave(harness);
    },
  );

  testWidgets(
    'the same call fits a short, wide phone in landscape with no overflow',
    (tester) async {
      final harness = await _connected(tester, const [
        _me,
        _aliceSharingWithCameraOn,
        _bobOnCameraOnly,
      ], size: const Size(844, 390));
      addTearDown(harness.dispose);

      expect(tester.takeException(), isNull);

      await _leave(harness);
    },
  );

  testWidgets(
    'a camera-only call with several participants fits a tall, narrow phone '
    'with no overflow',
    (tester) async {
      final harness = await _connected(tester, const [
        _me,
        _aliceOnCameraOnly,
        _bobOnCameraOnly,
      ]);
      addTearDown(harness.dispose);

      expect(tester.takeException(), isNull);

      await _leave(harness);
    },
  );

  testWidgets(
    'a small call sits in a bounded room rather than a full-bleed void',
    (tester) async {
      final harness = await _connected(tester, const [
        _me,
        _aliceOnCameraOnly,
      ], size: const Size(1400, 900));
      addTearDown(harness.dispose);

      final wrap = tester.getRect(find.byType(AnimatedRosterWrap));
      expect(wrap.width, lessThanOrEqualTo(kContentColumnMax));

      await _leave(harness);
    },
  );
}
