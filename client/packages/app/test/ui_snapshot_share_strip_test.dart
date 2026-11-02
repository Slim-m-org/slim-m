// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share stage's control strip, the full screen controls and the row that
/// offers a stopped share back, at desktop and phone width. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts no overflow.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/features/voice/widgets/share_stage_grid.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

class _SoundSession extends FakeSession {
  @override
  bool hasScreenAudio(String identity) => true;
}

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _bo = VoiceParticipant(
  identity: 'u-bo',
  name: 'Bo',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _stageKey = Key('snapshot-stage');

// A busy picture, so the strip is judged over something that is not flat black.
const _picture = DecoratedBox(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      colors: [Color(0xFF3B6EA5), Color(0xFFE8C26A), Color(0xFFF4F4F0)],
    ),
  ),
);

ThemeData _theme(Brightness b) =>
    buildTheme(b, b == Brightness.dark ? AppTokens.dark : AppTokens.light);

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await expectSettled(tester, name, allowNoText: true);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

Future<void> _stage(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  required bool touch,
  required String name,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final harness = VoiceHarness();
  addTearDown(harness.dispose);
  final controller = harness.controllerWith(_SoundSession(), voiceApi());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(brightness),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ScreenShareStage(
                    key: _stageKey,
                    sharerName: _ada.name,
                    onStopWatching: () {},
                    onExpand: () {},
                    stripVolume: (hold) =>
                        shareStripVolume(_ada, controller, hold),
                    stripQuality: (hold) =>
                        shareStripQuality(_ada, controller, hold),
                    child: _picture,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final centre = tester.getCenter(find.byKey(_stageKey));
  if (touch) {
    await tester.tapAt(centre);
  } else {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(centre);
  }
  await _shoot(tester, name);
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('share strip desktop dark', (tester) async {
    await _stage(
      tester,
      size: const Size(900, 560),
      brightness: Brightness.dark,
      touch: false,
      name: 'share-strip-desktop-dark',
    );
  });

  testWidgets('share strip phone light', (tester) async {
    await _stage(
      tester,
      size: const Size(390, 340),
      brightness: Brightness.light,
      touch: true,
      name: 'share-strip-phone-light',
    );
  });

  for (final (label, size) in [
    ('desktop', const Size(1200, 700)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('fullscreen controls $label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final harness = VoiceHarness();
      addTearDown(harness.dispose);
      final session = _SoundSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      session.emitState(VoiceSessionState.connected);
      await tester.pump();
      session.emitParticipants(const [_ada]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: harness.container,
          child: RepaintBoundary(
            key: snapshotBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.dark),
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showFullscreenVideo(
                    context,
                    identity: _ada.identity,
                    label: "Ada's screen",
                    kind: FullscreenVideoKind.screenShare,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _shoot(tester, 'fullscreen-controls-$label-dark');
      await controller.leave();
    });
  }

  testWidgets('a stopped share is offered back', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            home: const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
          ),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    session.emitParticipants(const [_ada, _bo]);
    harness.container.read(shareWatchProvider.notifier).stop('u-ada');
    await _shoot(tester, 'share-stopped-row-desktop-light');
    await controller.leave();
    await tester.pumpWidget(const SizedBox.shrink());
    harness.dispose();
  });
}
