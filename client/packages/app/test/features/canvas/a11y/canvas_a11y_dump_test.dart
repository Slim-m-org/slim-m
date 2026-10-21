// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accessibility probe: writes the semantics tree of every canvas state to
/// `$A11Y_DUMP_DIR/<state>.txt`, one line per node with its label, role and
/// actions. It asserts only that each state has controls, so it passes; the
/// listings are for reading.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

void main() {
  for (final entry in {'desktop': desktopSize, 'phone': phoneSize}.entries) {
    final size = entry.value;
    final name = entry.key;

    a11yTest('$name: the default, pen armed and the overflow menu', (
      tester,
    ) async {
      await pumpA11yCanvas(
        tester,
        size: size,
        objects: [
          canvasObjectJson('s1'),
          canvasNoteJson('n1', seq: 2, x: 100, text: 'hello world'),
          canvasObjectJson('far', x: 3000, seq: 3),
        ],
      );
      dumpSemantics(tester, '$name-1-default');
      await pressKey(tester, LogicalKeyboardKey.keyP);
      dumpSemantics(tester, '$name-2-pen-armed');
      await openOverflowByKeyboard(tester);

      expect(
        dumpSemantics(tester, '$name-3-overflow-open'),
        contains('Paste image'),
      );
    });

    a11yTest('$name: fullscreen folded, then revealed', (tester) async {
      final rig = await pumpA11yCanvas(tester, size: size);
      rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
      await settle(tester);
      dumpSemantics(tester, '$name-4-fullscreen-folded');
      await tester.tap(find.bySemanticsLabel('Show controls'));
      await settle(tester);

      expect(
        dumpSemantics(tester, '$name-5-fullscreen-revealed'),
        contains('Mute'),
      );
    });

    a11yTest('$name: the activity panel', (tester) async {
      await pumpA11yCanvas(tester, size: size);
      await runOverflowItem(tester, 'Show activity log');
      dumpSemantics(tester, '$name-6-activity-panel');
    });
  }
}
