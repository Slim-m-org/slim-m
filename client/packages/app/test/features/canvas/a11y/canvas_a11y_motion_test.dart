// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas under reduce motion: each case runs the scene at full motion (to prove the check can see animation) and reduced, by the OS switch or a screen reader.
/// Loops must stop ticking and transitions land in the first frame.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_dock_collapse.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_rtc/rtc.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

const _speaking = VoiceParticipant(
  identity: 'user-priya',
  name: 'Priya',
  isSpeaking: true,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _modes = {
  'reduce motion': (reduce: true, screenReader: false),
  'a screen reader': (reduce: false, screenReader: true),
};

void main() {
  a11yTest('full motion: the speaking ring keeps ticking (control)', (
    tester,
  ) async {
    await pumpA11yCanvas(tester, participants: [meParticipant, _speaking]);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  a11yTest('full motion: the dock takes time to unfold (control)', (
    tester,
  ) async {
    final rig = await pumpA11yCanvas(tester);
    rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
    await settle(tester);
    final folded = tester.getSize(find.byType(CanvasDockCollapse)).height;

    await tester.tap(find.bySemanticsLabel('Show controls'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final partway = tester.getSize(find.byType(CanvasDockCollapse)).height;
    await settle(tester);
    final open = tester.getSize(find.byType(CanvasDockCollapse)).height;
    expect(partway, greaterThan(folded));
    expect(partway, lessThan(open));
  });

  a11yTest('the folded dock handle is its own small semantics node', (
    tester,
  ) async {
    final rig = await pumpA11yCanvas(tester);
    rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
    await settle(tester);

    expect(
      tester.getSize(find.bySemanticsLabel('Show controls')).height,
      lessThan(100),
      reason: 'merged into the pane it reads as one full-screen button',
    );
  });

  for (final mode in _modes.entries) {
    group('with ${mode.key}', () {
      a11yTest('the speaking ring stops ticking', (tester) async {
        await pumpA11yCanvas(
          tester,
          participants: [meParticipant, _speaking],
          reduceMotion: mode.value.reduce,
          screenReader: mode.value.screenReader,
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.binding.transientCallbackCount, 0);
      });

      a11yTest('a remote cursor does not glide', (tester) async {
        final rig = await pumpA11yCanvas(
          tester,
          call: false,
          reduceMotion: mode.value.reduce,
          screenReader: mode.value.screenReader,
        );
        for (final x in [100.0, 300.0]) {
          rig.fixture.events.add(
            api.CanvasCursorMoved(
              channelId: 'c1',
              userId: 'user-priya',
              x: x,
              y: 100,
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(tester.binding.transientCallbackCount, 0);
      });

      a11yTest('the fullscreen dock unfolds in the first frame', (
        tester,
      ) async {
        final rig = await pumpA11yCanvas(
          tester,
          reduceMotion: mode.value.reduce,
          screenReader: mode.value.screenReader,
        );
        rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
        await settle(tester);
        final folded = tester.getSize(find.byType(CanvasDockCollapse)).height;

        await tester.tap(find.bySemanticsLabel('Show controls'));
        await tester.pump();

        expect(
          tester.getSize(find.byType(CanvasDockCollapse)).height,
          greaterThan(folded),
        );
        final first = tester.getSize(find.byType(CanvasDockCollapse)).height;
        await settle(tester);
        expect(tester.getSize(find.byType(CanvasDockCollapse)).height, first);
      });

      a11yTest('a tile control is fully visible the frame it takes focus', (
        tester,
      ) async {
        await pumpA11yCanvas(
          tester,
          reduceMotion: mode.value.reduce,
          screenReader: mode.value.screenReader,
        );
        expect(await tabTo(tester, 'Lock this tile'), isTrue);
        await tester.pump();

        final fade = tester.renderObject<RenderAnimatedOpacity>(
          find
              .descendant(
                of: find.byType(CanvasPresenceManipulableTile).first,
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
        expect(fade.opacity.value, 1);
      });

      a11yTest('a sheet is on screen the frame it opens', (tester) async {
        await pumpA11yCanvas(
          tester,
          size: phoneSize,
          reduceMotion: mode.value.reduce,
          screenReader: mode.value.screenReader,
        );
        await tester.tap(find.bySemanticsLabel('More canvas actions'));
        await tester.pump();
        await tester.tap(find.text('Participants'));
        await tester.pump();
        await tester.pump();

        final scrim = tester.firstRenderObject<RenderBox>(
          find.byType(BottomSheet),
        );
        expect(
          scrim.localToGlobal(Offset.zero).dy,
          lessThan(tester.view.physicalSize.height - 100),
        );
      });
    });
  }
}
