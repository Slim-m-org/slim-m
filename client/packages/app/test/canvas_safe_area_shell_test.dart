// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gate `ui_snapshot_test.dart` never carried: a real notch, and a call
/// live elsewhere so every fixed bar the compact shell and the rail can show
/// is actually on screen, driven through the real shell rather than
/// `CanvasPane` in isolation. `canvas_pane_test.dart`'s own geometry test
/// cannot see either defect this guards, because neither exists until the
/// pane is a middle child of `HomeShell`'s column or a sibling of the rail.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/voice_strip_indicator.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

/// Live in a different channel than the one whose canvas the tests open.
const _callElsewhere = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
);

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester,
  Size size, {
  required double top,
  required double bottom,
  required double left,
  required double right,
}) async {
  final fixture = await fixtureContainer(
    extraOverrides: [
      canvasOpenProvider.overrideWith((ref) => 'c-general'),
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, _callElsewhere),
      ),
    ],
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(
    top: top,
    bottom: bottom,
    left: left,
    right: right,
  );
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  return fixture;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    'the compact shell insets the banner, the canvas and the strip exactly '
    'once, not once each',
    (tester) async {
      const top = 59.0;
      const bottom = 34.0;
      final fixture = await _open(
        tester,
        const Size(390, 844),
        top: top,
        bottom: bottom,
        left: 0,
        right: 0,
      );

      // No gap between the banner and the bar: a sibling SafeArea on the pane used to reserve this inset a second time.
      final railBarHeight = tester
          .getSize(find.byType(RailConnectionBar))
          .height;
      expect(
        tester.getTopLeft(find.byType(CanvasBar)).dy,
        closeTo(top + railBarHeight, 0.5),
        reason: 'the banner must clear the notch and the bar must not also',
      );

      // No gap between the canvas and the strip below it either.
      expect(
        tester.getBottomLeft(find.byType(CanvasSurface)).dy,
        closeTo(tester.getTopLeft(find.byType(VoiceStripIndicator)).dy, 0.5),
      );
      expect(
        tester.getBottomLeft(find.byType(VoiceStripIndicator)).dy,
        lessThanOrEqualTo(844 - bottom + 0.5),
        reason: 'the strip itself must clear the home indicator',
      );

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );

  testWidgets(
    'the two-pane rail layout does not re-inset the notch the rail already '
    'covers',
    (tester) async {
      const left = 59.0;
      const right = 34.0;
      final fixture = await _open(
        tester,
        const Size(844, 390),
        top: 0,
        bottom: 0,
        left: left,
        right: right,
      );

      // The canvas starts right after the rail's own hairline divider (backlog item 58 shrank its reserved width to that, from rowPointer), never a second notch-width further in.
      expect(
        tester.getTopLeft(find.byType(CanvasSurface)).dx,
        closeTo(ChannelRail.mediumWidth + 1, 0.5),
      );
      expect(
        tester.getTopRight(find.byType(CanvasSurface)).dx,
        lessThanOrEqualTo(844 - right + 0.5),
        reason: 'the true right edge is still the canvas to protect',
      );

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );
}
