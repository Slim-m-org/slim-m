// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas tools never scroll inside the dock at a desktop pane width, so the eraser is never cut to a sliver.
/// A 1440 px window with the member list docked once drew it 7 px wide, behind the stamp's reserved caret.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/call_solo.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';

const _window = 1400.0;

/// The tool strip is the dock's one sideways scroller.
double _toolOverflow(WidgetTester tester) {
  final strip = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
  );
  return tester.state<ScrollableState>(strip).position.maxScrollExtent;
}

void main() {
  for (final stamps in [false, true]) {
    testWidgets('the tool strip fits at every desktop pane width (stamps '
        '$stamps)', (tester) async {
      tester.view.physicalSize = const Size(_window, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (var width = 400.0; width <= 1200; width += 4) {
        await pumpCanvasCallDock(
          tester,
          withCall: true,
          callVoice: const VoiceFlags(
            state: VoiceSessionState.connected,
            channelId: 'c1',
          ),
          canvas: buildCanvasDockData(),
          width: width,
          touch: false,
          overrides: [
            canvasStampsSupportedProvider.overrideWithValue(stamps),
            callAloneProvider.overrideWithValue(false),
            myChannelPermissionsProvider(
              'c1',
            ).overrideWithValue(Perm.connect | Perm.speak | Perm.useSoundboard),
          ],
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'width $width');
        expect(
          _toolOverflow(tester),
          lessThan(0.5),
          reason:
              'at a $width px pane the tools scroll, cutting off the eraser',
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }
}
