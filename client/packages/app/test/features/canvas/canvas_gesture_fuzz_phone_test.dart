// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gesture fuzz at a 390 wide phone window with the Android platform
/// override, where the compact dock, touch hit reach and touch handles apply.
///
/// `isDesktopHost` is true under `flutter test` on Linux, and the canvas
/// branches on window width and `AppTouchTargets` rather than on it, so the
/// width and the platform override are what put the pane on its mobile path.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_gesture_fuzz_driver.dart';
import 'canvas_gesture_fuzz_rig.dart';

const _seeds = int.fromEnvironment('FUZZ_SEEDS', defaultValue: 12);
const _steps = int.fromEnvironment('FUZZ_STEPS', defaultValue: 90);
const _firstSeed = int.fromEnvironment('FUZZ_FIRST_SEED', defaultValue: 1);

void main() {
  for (final midSwitch in [true, false]) {
    final label = midSwitch ? 'phone' : 'phone no mid-gesture tool switch';
    group(label, () {
      for (var seed = _firstSeed; seed < _firstSeed + _seeds; seed++) {
        testWidgets('gesture fuzz, seed $seed', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            final rig = await FuzzRig.start(tester, phone: true);
            final fuzz = CanvasGestureFuzz(
              rig,
              seed,
              toolSwitchMidGesture: midSwitch,
            );
            try {
              await fuzz.run(_steps);
            } finally {
              await fuzz.finish();
            }
            reportFuzz(fuzz, mode: label);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    });
  }
}
