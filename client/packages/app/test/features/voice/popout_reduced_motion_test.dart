// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pop-out's hover-revealed controls obey reduced motion: they are fully
/// shown on the frame the pointer arrives, with no fade.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/reduced_motion_harness.dart';
import 'voice_controller_harness.dart';

const _feed = (identity: 'u-ada', name: 'Ada', kind: FeedKind.screenShare);

class _Call extends VoiceController {
  _Call(super.ref, FakeSession session) : super(session: session) {
    state = const VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
    );
  }
}

Future<double> _controlsOpacityAfterHover(
  WidgetTester tester, {
  required bool reduced,
}) async {
  final container = ProviderContainer(
    overrides: [
      voiceControllerProvider.overrideWith((ref) => _Call(ref, FakeSession())),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    reducedMotionApp(
      container: container,
      disableAnimations: reduced,
      child: PopOutWindowView(
        feed: _feed,
        frame: PopOutFrame(
          onMoveStart: () {},
          onResizeStart: (_) {},
          onClose: () {},
        ),
      ),
    ),
  );
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(5, 5));
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(tester.getCenter(find.byKey(popOutWindowKey)));
  await tester.pump();
  final bar = find.ancestor(
    of: find.byIcon(AppIcons.leaveCall),
    matching: find.byType(AnimatedOpacity),
  );
  return tester.renderObject<RenderAnimatedOpacity>(bar.first).opacity.value;
}

void main() {
  testWidgets('with motion allowed the controls fade in over a beat', (
    tester,
  ) async {
    expect(
      await _controlsOpacityAfterHover(tester, reduced: false),
      lessThan(1),
    );
  });

  testWidgets('with reduced motion the controls are shown at once', (
    tester,
  ) async {
    expect(await _controlsOpacityAfterHover(tester, reduced: true), 1);
  });
}
