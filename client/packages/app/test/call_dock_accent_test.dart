// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0047, point 3: accent marks only a tool or an open mode. A live
/// mic is plain with a level bar, a muted mic is the slashed icon in a danger
/// outline, a camera that is on stays plain, and sharing keeps the accent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

BoxDecoration _chip(WidgetTester tester, IconData icon) {
  final container = tester.widget<Container>(
    find
        .ancestor(of: find.byIcon(icon), matching: find.byType(Container))
        .first,
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  const tokens = AppTokens.light;

  testWidgets(
    'a live mic is plain and carries a level bar sized to its level',
    (tester) async {
      await pumpControls(
        tester,
        const VoiceFlags(
          state: VoiceSessionState.connected,
          microphoneEnabled: true,
        ),
        extraOverrides: [localMicLevelProvider.overrideWithValue(0.5)],
      );
      expect(_chip(tester, AppIcons.mic).color, tokens.surfaceRaised);
      final bar = find.byKey(const ValueKey('call-dock-level'));
      expect(bar, findsOneWidget);
      final track = tester.getSize(
        find.ancestor(of: bar, matching: find.byType(Align)).first,
      );
      expect(tester.getSize(bar).width, closeTo(track.width * 0.5, 0.5));
      expect(tester.getSize(bar).height, 2);
    },
  );

  testWidgets('a muted mic is the slashed icon in a danger outline, no bar', (
    tester,
  ) async {
    await pumpControls(
      tester,
      const VoiceFlags(
        state: VoiceSessionState.connected,
        microphoneEnabled: false,
      ),
      extraOverrides: [localMicLevelProvider.overrideWithValue(0.5)],
    );
    expect(find.byIcon(AppIcons.mic), findsNothing);
    final chip = _chip(tester, AppIcons.micOff);
    expect(chip.color, Colors.transparent);
    expect((chip.border! as Border).top.color, tokens.dangerBorder);
    expect(find.byKey(const ValueKey('call-dock-level')), findsNothing);
  });

  testWidgets('a camera that is on is not accented', (tester) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, cameraEnabled: true),
    );
    expect(_chip(tester, AppIcons.camera).color, tokens.surfaceRaised);
  });

  testWidgets('a live share keeps the accent, since sharing is an open mode', (
    tester,
  ) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, screenSharing: true),
    );
    expect(_chip(tester, AppIcons.screenShare).color, tokens.accentSoft);
  });
}
