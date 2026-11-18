// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone-width call dock that cannot hold the soundboard gives it a row of its own above the call row, with leave still beside the row it ends.
/// At 390 px a break-it tester saw the soundboard alone under the camera and leave floating between the two lines.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

Finder _button(String tooltipStart) => find.byWidgetPredicate(
  (w) => w is CallDockButton && w.tooltip.startsWith(tooltipStart),
);

void main() {
  testWidgets('the soundboard spills above the call row, leave stays level '
      'with it', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (var width = 340.0; width <= 400; width += 4) {
      await pumpVoiceCallDock(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected, channelId: 'c1'),
        width: width,
        touch: true,
        extraOverrides: [
          myChannelPermissionsProvider(
            'c1',
          ).overrideWithValue(Perm.connect | Perm.speak | Perm.useSoundboard),
        ],
      );
      await tester.pump();
      final reason = 'at $width px';
      expect(tester.takeException(), isNull, reason: reason);
      final soundboard = tester.getRect(_button('Soundboard'));
      final deafen = tester.getRect(_button('Deafen'));
      final leave = tester.getRect(_button('Leave call'));
      expect(
        leave.center.dy,
        closeTo(deafen.center.dy, 0.5),
        reason: 'leave ends the call row $reason',
      );
      expect(
        soundboard.center.dy,
        anyOf(closeTo(deafen.center.dy, 0.5), lessThan(deafen.top)),
        reason: 'the soundboard is on the call row or above it $reason',
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
