// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fitted call stage in a box with no height: it renders empty, not an error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stage_fit_view.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  testWidgets('a zero-height stage with a share in the call renders no error', (
    tester,
  ) async {
    final harness = VoiceHarness();
    addTearDown(harness.dispose);
    final controller = harness.controllerWith(FakeSession(), voiceApi());
    const sharer = VoiceParticipant(
      identity: 'u1',
      name: 'User 1',
      isLocal: false,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: true,
      isCameraOn: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 0,
            child: CallStageFitView(
              participants: const [sharer],
              shares: const [sharer],
              focused: null,
              directStage: const SizedBox.shrink(),
              controller: controller,
              onOpenProfile: (_, _) {},
              onStopWatching: (_) {},
              onFocus: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
