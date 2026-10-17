// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A single tap toggles the chrome instantly, a fast double tap enters full
/// screen only where that gesture is turned on, and an idle, playing video
/// hides its own chrome and brings it back on tap.
///
/// One real `Player` for the whole file, created in [setUpAll] and disposed
/// in [tearDownAll], rather than one per test: media_kit's native player is
/// expensive to spin up and tear down, and each test only needs it to hold
/// still while the widget above it changes, not a fresh instance of its own.
/// Ordered so the one test that starts real playback runs last, since
/// nothing after it depends on the player still being paused.
library;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_app/src/features/voice/widgets/video_playback_controls.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness({
  required Player player,
  bool touchGestures = true,
  VoidCallback? onToggleFullscreen,
  Duration autoHideDelay = kVideoControlsAutoHide,
}) {
  return AppTouchTargets(
    enabled: touchGestures,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 180,
          child: VideoPlaybackControls(
            player: player,
            isFullscreen: false,
            onToggleFullscreen: onToggleFullscreen ?? () {},
            autoHideDelay: autoHideDelay,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    ),
  );
}

double _barOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

/// A tap near the top of the frame, clear of the touch-sized control bar
/// pinned to the bottom - the bar alone can run taller than this harness's
/// whole frame, so a tap at the frame's center can land on the bar itself
/// rather than the plain video area behind it.
Future<void> _tapVideoArea(WidgetTester tester) {
  final topLeft = tester.getTopLeft(find.byType(VideoPlaybackControls));
  return tester.tapAt(topLeft + const Offset(20, 12));
}

void main() {
  late Player player;

  setUpAll(() {
    MediaKit.ensureInitialized();
    player = Player();
  });

  tearDownAll(() => player.dispose());

  testWidgets(
    'a single tap toggles the bar immediately, well under the double tap '
    'timeout',
    (tester) async {
      await tester.pumpWidget(_harness(player: player));
      expect(_barOpacity(tester), 1);

      await _tapVideoArea(tester);
      await tester.pump(kDoubleTapTimeout ~/ 4);
      expect(_barOpacity(tester), 0);

      // Past the double tap window, so this is its own single tap.
      await tester.pump(kDoubleTapTimeout);
      await _tapVideoArea(tester);
      await tester.pump(kDoubleTapTimeout ~/ 4);
      expect(_barOpacity(tester), 1);
    },
  );

  testWidgets('a fast double tap enters full screen when touch is on', (
    tester,
  ) async {
    var toggled = 0;
    await tester.pumpWidget(
      _harness(player: player, onToggleFullscreen: () => toggled++),
    );

    await _tapVideoArea(tester);
    await tester.pump(const Duration(milliseconds: 50));
    await _tapVideoArea(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(toggled, 1);
  });

  testWidgets(
    'a fast double tap does nothing on a wide window with no touch gestures',
    (tester) async {
      var toggled = 0;
      await tester.pumpWidget(
        _harness(
          player: player,
          touchGestures: false,
          onToggleFullscreen: () => toggled++,
        ),
      );

      await _tapVideoArea(tester);
      await tester.pump(const Duration(milliseconds: 50));
      await _tapVideoArea(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(toggled, 0);
    },
  );

  testWidgets('controls stay up while paused, however long it sits idle', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(player: player, autoHideDelay: const Duration(milliseconds: 20)),
    );

    await tester.pump(const Duration(seconds: 5));
    expect(_barOpacity(tester), 1);
  });

  testWidgets('an idle playing video hides its bar and a tap brings it back', (
    tester,
  ) async {
    await tester.runAsync(() => player.play());

    await tester.pumpWidget(
      _harness(player: player, autoHideDelay: const Duration(milliseconds: 30)),
    );
    expect(_barOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 100));
    expect(_barOpacity(tester), 0);

    // Under autoHideDelay, so this predates the next hide the tap rearms.
    await _tapVideoArea(tester);
    await tester.pump(const Duration(milliseconds: 10));
    expect(_barOpacity(tester), 1);
  });
}
