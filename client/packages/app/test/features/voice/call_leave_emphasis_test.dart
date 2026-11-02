// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0047 point 2: Leave is the one control whose danger outline is
/// always on, and it is heavier than a muted mic's or a deafened headset's,
/// which are states. Danger is outlined, never filled, at rest.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _deafened = VoiceFlags(
  state: VoiceSessionState.connected,
  deafened: true,
);

BoxDecoration? _face(WidgetTester tester, Finder control) {
  final faces = find.descendant(
    of: control,
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).border?.top.color ==
              AppTokens.light.dangerBorder,
    ),
  );
  if (faces.evaluate().isEmpty) return null;
  return tester.widget<Container>(faces.first).decoration! as BoxDecoration;
}

void main() {
  testWidgets('Leave has a heavier danger outline than a deafened headset', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpVoiceCallDock(tester, _deafened);

    final leave = _face(tester, find.byTooltip(RegExp('^Leave call')))!;
    final deafen = _face(tester, find.byTooltip(RegExp('^Undeafen')))!;

    expect(leave.border!.top.width, 2);
    expect(deafen.border!.top.width, 1);
    expect(leave.color, Colors.transparent, reason: 'never filled at rest');
  });

  testWidgets('only Leave fills on hover', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpVoiceCallDock(tester, _deafened);

    Color? hoverOf(Finder control) => tester
        .widget<InkWell>(
          find.descendant(
            of: control,
            matching: find.byWidgetPredicate((w) => w is InkWell),
          ),
        )
        .hoverColor;

    expect(hoverOf(find.byTooltip(RegExp('^Leave call'))), isNotNull);
    expect(hoverOf(find.byTooltip(RegExp('^Undeafen'))), isNull);
  });
}
