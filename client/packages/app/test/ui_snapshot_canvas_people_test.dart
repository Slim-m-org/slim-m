// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one people panel (decision 0095) open on a canvas whose viewer follows someone, at a phone and a desktop width in both themes.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/canvas/canvas_pane_harness.dart';
import 'features/voice/voice_controller_harness.dart';
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

class _Voice extends VoiceController {
  _Voice(super.ref) : super(session: FakeSession()) {
    state = const VoiceState(
      channelId: 'c1',
      state: VoiceSessionState.connected,
      participants: [
        VoiceParticipant(
          identity: 'me',
          name: 'Nick',
          isSpeaking: false,
          isMuted: false,
          isLocal: true,
          isScreenSharing: false,
        ),
        VoiceParticipant(
          identity: 'user-ada',
          name: 'Ada',
          isSpeaking: true,
          isMuted: false,
          isLocal: false,
          isScreenSharing: false,
        ),
        VoiceParticipant(
          identity: 'user-bo',
          name: 'Bo',
          isSpeaking: false,
          isMuted: true,
          isLocal: false,
          isScreenSharing: false,
        ),
      ],
    );
  }
}

Future<void> _capture(
  WidgetTester tester,
  Size size,
  String theme,
  String name,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [voiceControllerProvider.overrideWith(_Voice.new)],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            snapshotThemes[theme]!.brightness,
            snapshotThemes[theme]!.tokens,
          ),
          home: const Scaffold(body: CanvasPane(channelId: 'c1')),
        ),
      ),
    ),
  );
  await tester.pump();
  final engine = container.read(canvasEngineProvider('c1').notifier);
  engine.cursors
    ..upsert(id: 'user-ada', x: 500, y: 300, label: 'Ada', colorIndex: 1)
    ..upsert(id: 'user-cy', x: 900, y: 500, label: 'Cy', colorIndex: 2);
  await tester.pump(const Duration(milliseconds: 350));
  engine.viewRelay.follow('user-ada');
  await _untilViewStops(tester);
  await tester.tap(find.byTooltip('People here'));
  // On a phone the sheet covers part of the board, so the followed view refits once more.
  await _untilViewStops(tester);
  await expectSettled(tester, name, allowNoText: true);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

/// The follow camera eases toward its target, so its zoom label creeps for a while; wait until it holds still.
Future<void> _untilViewStops(WidgetTester tester) async {
  var last = renderedText(tester);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final now = renderedText(tester);
    if (now.join('|') == last.join('|')) return;
    last = now;
  }
  fail('the followed view never came to rest');
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final theme in const ['dark', 'light']) {
    for (final (label, size) in [
      ('phone', const Size(390, 844)),
      ('desktop', const Size(1280, 800)),
    ]) {
      testWidgets('canvas people $label $theme', (tester) async {
        await _capture(tester, size, theme, 'canvas-people-$label-$theme');
      });
    }
  }
}
