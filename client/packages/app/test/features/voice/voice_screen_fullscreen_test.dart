// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera tile can be expanded full screen now: the owner's report was
/// "no way to full screen a camera", which turned out to be true in a wider
/// sense than the report itself - a *remote* participant's camera was never
/// rendered anywhere in the call UI at all, only the local self-preview, so
/// there was nothing to expand into for anyone but yourself.
///
/// Covers the render, the expand affordance, exiting by the close control
/// and by Escape, and the two ways a fullscreen view must close itself
/// rather than be left showing something no longer true: the participant
/// leaving the call, and that participant turning the very camera off this
/// view opened for.
library;

import '../../support/menu_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
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

const _aliceOnCamera = VoiceParticipant(
  identity: 'user-2',
  name: 'Alice',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
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

/// Joins, connects, seats Alice with her camera already on, and opens her
/// tile full screen - the shared starting point every test here drives
/// further.
class _Fixture {
  _Fixture(this.harness, this.session);

  final VoiceHarness harness;
  final FakeSession session;

  /// Stops the heartbeat `connected` started, in the test body itself: the
  /// pending-timer check runs before `addTearDown`, the same trap
  /// `sign_out_leaves_call_test.dart` already documents.
  Future<void> leave() =>
      harness.container.read(voiceControllerProvider.notifier).leave();
}

Future<_Fixture> _openedFullscreen(WidgetTester tester) async {
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
  session.emitParticipants(const [_me, _aliceOnCamera]);
  await tester.pump();
  await tester.pumpAndSettle();

  await rightClickMenu(tester, find.text('Alice'));
  await tester.tap(find.text('Camera full screen'));
  await tester.pumpAndSettle();
  expect(find.byType(FullscreenVideoView), findsOneWidget);

  return _Fixture(harness, session);
}

void main() {
  testWidgets(
    "a remote camera renders on its tile and offers a way to view it full "
    'screen',
    (tester) async {
      final fixture = await _openedFullscreen(tester);
      addTearDown(fixture.harness.dispose);

      expect(
        find.byKey(const Key('fake-camera-view-user-2')),
        findsWidgets,
        reason:
            "Alice's camera is on, so both her tile and the fullscreen "
            'view must show the live feed',
      );
      await fixture.leave();
    },
  );

  testWidgets('the close button exits full screen', (tester) async {
    final fixture = await _openedFullscreen(tester);
    addTearDown(fixture.harness.dispose);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppIconButton && w.semanticLabel == 'Exit full screen',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenVideoView), findsNothing);
    await fixture.leave();
  });

  testWidgets('Escape exits full screen', (tester) async {
    final fixture = await _openedFullscreen(tester);
    addTearDown(fixture.harness.dispose);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenVideoView), findsNothing);
    await fixture.leave();
  });

  testWidgets(
    'full screen exits itself if the participant turns the camera off '
    'while it is open',
    (tester) async {
      final fixture = await _openedFullscreen(tester);
      addTearDown(fixture.harness.dispose);

      fixture.session.emitParticipants(const [
        _me,
        VoiceParticipant(
          identity: 'user-2',
          name: 'Alice',
          isLocal: false,
          isSpeaking: false,
          isMuted: false,
          isScreenSharing: false,
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.byType(FullscreenVideoView), findsNothing);
      await fixture.leave();
    },
  );

  testWidgets(
    'full screen exits itself if the participant leaves the call while it '
    'is open',
    (tester) async {
      final fixture = await _openedFullscreen(tester);
      addTearDown(fixture.harness.dispose);

      fixture.session.emitParticipants(const [_me]);
      await tester.pumpAndSettle();

      expect(find.byType(FullscreenVideoView), findsNothing);
      await fixture.leave();
    },
  );
}
