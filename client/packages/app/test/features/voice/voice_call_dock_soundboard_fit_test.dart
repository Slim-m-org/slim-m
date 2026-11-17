// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's one-row fit counts the soundboard button, so a narrow stage
/// with the soundboard and the canvas toggle never draws one button under another.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _inCall = VoiceFlags(state: VoiceSessionState.connected, channelId: 'c1');

const _window = 1400.0;

Future<void> _expectNoOverlap(
  WidgetTester tester, {
  required double width,
  required bool touch,
}) async {
  await pumpVoiceCallDock(
    tester,
    _inCall,
    canvasChannelId: 'c1',
    width: width,
    touch: touch,
    extraOverrides: [
      myChannelPermissionsProvider(
        'c1',
      ).overrideWithValue(Perm.connect | Perm.speak | Perm.useSoundboard),
    ],
  );
  await tester.pump();
  expect(tester.takeException(), isNull, reason: 'width $width');
  expect(find.bySemanticsLabel('Soundboard'), findsOneWidget);
  final rects = [
    for (final e in find.bySubtype<CallDockButton>().evaluate())
      tester.getRect(find.byElementPredicate((x) => x == e)),
  ];
  final left = (_window - width) / 2;
  for (var i = 0; i < rects.length; i++) {
    expect(rects[i].right, lessThanOrEqualTo(left + width + 0.01));
    expect(rects[i].left, greaterThanOrEqualTo(left - 0.01));
    for (var j = i + 1; j < rects.length; j++) {
      final overlap = rects[i].intersect(rects[j]);
      expect(
        overlap.width > 0.01 && overlap.height > 0.01,
        isFalse,
        reason: 'buttons $i and $j overlap at width $width (touch $touch)',
      );
    }
  }
}

void main() {
  for (final touch in [false, true]) {
    testWidgets('no two dock buttons overlap at any width (touch $touch)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(_window, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (var width = 340.0; width <= 720; width += 4) {
        await _expectNoOverlap(tester, width: width, touch: touch);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }
}
