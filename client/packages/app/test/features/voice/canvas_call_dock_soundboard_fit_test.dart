// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// With the canvas open beside a call, the dock's row choice counts the
/// soundboard button, so no width draws the canvas toggle under leave.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/canvas_call_dock_fixtures.dart';

const _window = 1400.0;

Future<void> _expectNoOverlap(
  WidgetTester tester, {
  required double width,
  required bool cameraOn,
}) async {
  await pumpCanvasCallDock(
    tester,
    withCall: true,
    callVoice: VoiceFlags(
      state: VoiceSessionState.connected,
      channelId: 'c1',
      cameraEnabled: cameraOn,
    ),
    canFlipCamera: cameraOn,
    canvas: buildCanvasDockData(),
    width: width,
    touch: false,
    overrides: [
      myChannelPermissionsProvider(
        'c1',
      ).overrideWithValue(Perm.connect | Perm.speak | Perm.useSoundboard),
    ],
  );
  await tester.pump();
  final reason = 'width $width, camera $cameraOn';
  expect(tester.takeException(), isNull, reason: reason);
  expect(find.bySemanticsLabel('Soundboard'), findsOneWidget, reason: reason);
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
        reason: 'buttons $i and $j overlap at $reason',
      );
    }
  }
}

void main() {
  for (final cameraOn in [false, true]) {
    testWidgets('no two buttons overlap with the canvas open at any pane '
        'width (camera $cameraOn)', (tester) async {
      tester.view.physicalSize = const Size(_window, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (var width = 340.0; width <= 820; width += 4) {
        await _expectNoOverlap(tester, width: width, cameraOn: cameraOn);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }
}
