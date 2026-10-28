// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A blank canvas otherwise looks identical to a broken one, or to one still
/// loading: a faint lattice with nothing on it. This is the sighted-only
/// invitation to draw a first mark, which disappears the instant there is
/// something to look at instead.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane_hints.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../canvas/canvas_pane_harness.dart';
import 'voice_controller_harness.dart';

void main() {
  testWidgets(
    'a phone-width canvas gets touch-first pan/zoom wording, since nothing '
    'else in the UI ever states the pinch/two-finger gestures',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);

      expect(
        find.textContaining('Drag with two fingers to pan'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a desktop-width canvas gets pointer-first pan/zoom wording', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container);

    expect(find.textContaining('Scroll to pan'), findsOneWidget);
  });

  testWidgets(
    'an explicit AppTouchTargets override wins over the window width',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const Scaffold(
              body: AppTouchTargets(
                enabled: true,
                child: CanvasPane(channelId: 'c1'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('Drag with two fingers to pan'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a fresh canvas invites a first mark', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container);

    expect(find.text('Nothing on this canvas yet'), findsOneWidget);
  });

  testWidgets(
    "a call's participant tiles suppress the hint, where \"nothing here "
    'yet" would contradict the video feeds already on the canvas',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(
              ref,
              const VoiceState(
                channelId: 'c1',
                participants: [
                  VoiceParticipant(
                    identity: 'ada',
                    name: 'Ada',
                    isSpeaking: false,
                    isMuted: false,
                    isLocal: false,
                    isScreenSharing: false,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);

      expect(
        find.text('Nothing on this canvas yet'),
        findsNothing,
        reason:
            'the canvas has no drawings but is full of participant tiles; '
            'the empty prompt would read as a broken/contradictory state',
      );
    },
  );

  testWidgets('the hint is gone once a stroke lands', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container);
    expect(find.text('Nothing on this canvas yet'), findsOneWidget);

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveTo(const Offset(160, 140));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Nothing on this canvas yet'), findsNothing);
  });

  testWidgets(
    'the hint stays hidden behind objects fetched before the pane paints',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);

      expect(find.text('Nothing on this canvas yet'), findsNothing);
    },
  );

  /// canvas.md: a refused stroke leaves nothing drawn (`_document.kill`
  /// reduces `objectCount` back to zero), and the hint used to reappear
  /// with its own pen-tool invitation directly under a banner saying that
  /// exact drawing action had just failed - the timeout-freeze case named
  /// in `canvas-error-draw-forbidden-timeout-freeze`.
  testWidgets(
    "a refused stroke's error banner suppresses the empty hint, rather "
    'than inviting the same refused action again',
    (tester) async {
      final fixture = CanvasPaneFixture(placeStatus: 403);
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      expect(find.text('Nothing on this canvas yet'), findsOneWidget);

      final gesture = await tester.startGesture(const Offset(100, 100));
      await gesture.moveTo(const Offset(160, 140));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        find.text("You don't have permission to draw here right now."),
        findsOneWidget,
      );
      expect(
        find.text('Nothing on this canvas yet'),
        findsNothing,
        reason:
            'the refusal already explains the empty canvas; the pen-tool '
            'invitation would only invite the identical refusal again',
      );
    },
  );

  testWidgets(
    'a hard reset shows the loading hint rather than flashing the empty hint',
    (tester) async {
      final fixture = CanvasPaneFixture()..objects = [canvasObjectJson('a')];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      expect(find.text('Nothing on this canvas yet'), findsNothing);

      final gate = Completer<void>();
      fixture.viewportGate = gate;
      fixture.opsReset = true;

      final engine = container.read(canvasEngineProvider('c1').notifier);
      unawaited(engine.sync.catchUp());
      await tester.pump();

      expect(find.text('Nothing on this canvas yet'), findsNothing);
      expect(find.byType(CanvasLoadingHint), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Nothing on this canvas yet'), findsNothing);
    },
  );
}
