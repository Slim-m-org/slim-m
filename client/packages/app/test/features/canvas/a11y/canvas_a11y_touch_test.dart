// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Touch targets and large text at phone width: a target counts as 44 logical pixels only if a real hit test lands from the centre and four corners of a 44 pixel square.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';

import 'canvas_a11y_probe.dart';
import 'canvas_a11y_rig.dart';

const _tileText = ["on this call's canvas", 'this tile'];

/// The controls of the pane that a finger aims at, leaving out the call tiles
/// themselves (sized by the board's zoom) and their hover-revealed controls.
Iterable<SemRow> _fingerControls(WidgetTester tester) =>
    semanticsRows(tester, onlyControls: true).where(
      (r) =>
          !r.isDisabled &&
          r.accessibleName.isNotEmpty &&
          !_tileText.any(r.label.contains) &&
          !_objectNodes.hasMatch(r.label),
    );

/// The screen-reader nodes laid over board objects: a finger there presses the board, which selects the object.
final _objectNodes = RegExp(r'^(Drawing|Image|Shape|Note:)');

String _gaps(WidgetTester tester, Iterable<SemRow> rows) => [
  for (final row in rows)
    if (touchGaps(tester, row).isNotEmpty)
      '${row.name} ${row.rect.width.round()}x${row.rect.height.round()} '
          'misses ${touchGaps(tester, row).join(', ')}',
].join('\n');

void main() {
  group('touch targets at phone width', () {
    a11yTest('every control in the pane can be pressed from a 44 px square', (
      tester,
    ) async {
      await pumpA11yCanvas(
        tester,
        size: phoneSize,
        objects: [
          canvasObjectJson('s1'),
          // Past the 1920 wide board, so the outside-the-board pill is on screen.
          canvasObjectJson('far', x: 3000, seq: 3),
        ],
      );
      await pressKey(tester, LogicalKeyboardKey.keyP);

      expect(_gaps(tester, _fingerControls(tester)), isEmpty);
    });

    a11yTest('the fullscreen handle can be pressed from a 44 px square', (
      tester,
    ) async {
      final rig = await pumpA11yCanvas(tester, size: phoneSize);
      rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
      await settle(tester);

      final handle = rowsNamed(tester, 'Show controls');
      expect(handle, hasLength(1));
      expect(_gaps(tester, handle), isEmpty);
    });

    a11yTest('the Participants sheet rows are 44 px targets', (tester) async {
      await pumpA11yCanvas(tester, size: phoneSize);
      await runOverflowItem(tester, 'Participants');

      final rows = [
        for (final name in ['Priya', 'Sam']) ...rowsNamed(tester, name),
      ].where((r) => r.taps);
      expect(rows, isNotEmpty);
      expect(_gaps(tester, rows), isEmpty);
    });
  });

  group('large text', () {
    for (final scale in [1.5, 2.0]) {
      a11yTest('the pane lays out at ${scale}x text on a phone', (
        tester,
      ) async {
        await pumpA11yCanvas(
          tester,
          size: phoneSize,
          textScale: scale,
          objects: [canvasObjectJson('s1')],
        );

        expect(tester.takeException(), isNull);
      });
    }

    a11yTest('the pane lays out at 2x text on a desktop window', (
      tester,
    ) async {
      await pumpA11yCanvas(
        tester,
        textScale: 2,
        objects: [canvasObjectJson('s1')],
      );

      expect(tester.takeException(), isNull);
    });

    a11yTest('the view pills lay out at 3x text on a phone', (tester) async {
      await pumpA11yCanvas(
        tester,
        size: phoneSize,
        textScale: 3,
        objects: [canvasObjectJson('s1')],
      );

      final errors = <Object>[];
      Object? error;
      while ((error = tester.takeException()) != null) {
        errors.add(error!);
      }
      expect(errors, isEmpty, reason: errors.join('\n'));
    });
  });
}
