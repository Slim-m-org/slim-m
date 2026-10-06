// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `CallDockButton` (mute, camera, share, leave) used to draw a flat 44dp
/// chip at every width, on the stated reasoning that "one control size
/// across widths is what 'one layout' has to mean." The owner reported the
/// dock as needing to be "way more compact," and this row - the single
/// largest contributor to the dock's height - now follows `AppIconButton`'s
/// own already-shipped split instead: a fixed visible chip
/// (`AppSizes.controlMd`), with only the invisible tap area growing to
/// `AppSizes.rowTouch` at touch density.
///
/// Measured through the real rendered `Semantics` bounds, not the widget
/// tree: `AppFocusRing`'s own `Container` adds `border.dimensions` on top
/// of its declared padding (`BoxDecoration.padding` returns the border's
/// own width), so the expected size is derived from the same constants the
/// widget itself reads rather than a magic literal that would silently
/// drift if that wrapper's own padding ever changed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'voice_call_controls_harness.dart';

/// The shortcut hint every tooltip now carries; see the identical helper in
/// `voice_call_controls_test.dart`.
String _hint(AppAction action) => ' (${describeAppAction(action).join('+')})';

const _phone = Size(390, 844);
const _desktop = Size(1400, 900);

/// `AppFocusRing`'s own inset around whatever it wraps: its declared
/// padding plus the border stroke `BoxDecoration.padding` folds in.
double get _focusRingOverhead => 2 * (focusRingGap + focusRingWidth);

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpControls(
    tester,
    const VoiceFlags(state: VoiceSessionState.connected),
  );
}

void main() {
  final labels = [
    'Mute${_hint(AppAction.toggleMuteCall)}',
    'Turn on camera${_hint(AppAction.toggleCameraCall)}',
    'Share a screen${_hint(AppAction.toggleShareCall)}',
  ];

  testWidgets(
    'a pointer-width dock shrinks every call control below the old flat '
    '44dp chip',
    (tester) async {
      await _pumpAt(tester, _desktop);

      final expected = AppSizes.controlMd + _focusRingOverhead;
      for (final label in labels) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size, Size(expected, expected), reason: label);
        expect(
          size.shortestSide,
          lessThan(AppSizes.rowTouch + _focusRingOverhead),
          reason: '$label must be smaller than the old flat chip',
        );
      }
    },
  );

  testWidgets(
    'a touch-width dock still meets the 44dp floor on every call control',
    (tester) async {
      await _pumpAt(tester, _phone);

      final expected = AppSizes.rowTouch + _focusRingOverhead;
      for (final label in labels) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size, Size(expected, expected), reason: label);
        expect(
          size.shortestSide - _focusRingOverhead,
          greaterThanOrEqualTo(AppSizes.rowTouch),
          reason: '$label must not shrink below the touch minimum',
        );
      }
    },
  );
}
