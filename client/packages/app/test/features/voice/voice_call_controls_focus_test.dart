// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A keyboard sweep found `CallDockButton` (mute, camera, share, hang up)
/// reachable by Tab, but drawing Material's own translucent focus overlay
/// instead of this system's [AppTokens.focusRing] outline. Split out of
/// `voice_call_controls_test.dart` to keep that file under the review
/// budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

void main() {
  testWidgets(
    'a focused control button draws the design system\'s own focus ring, '
    'not the Material default overlay',
    (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );

      await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
      );

      expect(_hasControlFocusRing(tester), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(
        _hasControlFocusRing(tester),
        isTrue,
        reason:
            'InkWell draws Material\'s own translucent focus overlay by '
            'default; AppFocusRing is what replaces it with this design '
            'language\'s own outline token',
      );
    },
  );
}

/// Mirrors `context_menu_reachability_test.dart`'s own `_hasFocusRing`
/// helper, adapted for [AppFocusRing]'s `Container`-based ring rather than a
/// `foregroundDecoration` one.
bool _hasControlFocusRing(WidgetTester tester) => tester.any(
  find.byWidgetPredicate((w) {
    if (w is! Container) return false;
    final decoration = w.decoration;
    return decoration is BoxDecoration &&
        decoration.border?.top.color == AppTokens.light.focusRing;
  }),
);
