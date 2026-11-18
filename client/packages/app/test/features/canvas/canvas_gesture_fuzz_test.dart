// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Seeded random pointer sequences against the real canvas pane at desktop width: mouse, touch, stylus and trackpad, one to three pointers, cancels, tool switches, wheel and remote edits.
/// A second group holds tool changes until all pointers are up; `--dart-define=FUZZ_SEEDS` and `FUZZ_STEPS` widen a run.
library;

import 'package:flutter_test/flutter_test.dart';

import '../../support/fuzz_budget.dart';
import 'canvas_gesture_fuzz_driver.dart';
import 'canvas_gesture_fuzz_rig.dart';

const _seedsDefine = int.fromEnvironment('FUZZ_SEEDS');
final _seeds = _seedsDefine > 0 ? _seedsDefine : fuzzSeeds(full: 12, quick: 3);
const _steps = int.fromEnvironment('FUZZ_STEPS', defaultValue: 90);
const _firstSeed = int.fromEnvironment('FUZZ_FIRST_SEED', defaultValue: 1);

void main() {
  for (final midSwitch in [true, false]) {
    final label = midSwitch ? 'desktop' : 'desktop no mid-gesture tool switch';
    group(label, () {
      for (var seed = _firstSeed; seed < _firstSeed + _seeds; seed++) {
        testWidgets('gesture fuzz, seed $seed', (tester) async {
          final rig = await FuzzRig.start(tester, phone: false);
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
        });
      }
    });
  }
}
