// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasHistory]: what leaves a stack, what stays, and what a fresh edit does to redo.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_history.dart';

class _Rig {
  _Rig() {
    history = CanvasHistory<String, String>(
      CanvasHistoryHost(
        undoStep: (entry) async {
          if (gone.contains(entry)) history.markGone();
          return failing.contains(entry) || gone.contains(entry)
              ? null
              : '~$entry';
        },
        redoStep: (entry) async => entry.substring(1),
        isSkipped: (redo) => redo == '~skip',
        isNoRedo: (redo) => redo == '~none',
        isNoUndo: (undo) => undo == 'none',
        isDisposed: () => false,
        onError: errors.add,
      ),
    );
  }

  late final CanvasHistory<String, String> history;
  final failing = <String>{};
  final gone = <String>{};
  final errors = <String>[];
}

void main() {
  test('an undo moves the entry to redo, and a redo moves it back', () async {
    final rig = _Rig();
    rig.history.pushUndo('a');

    await rig.history.undo();
    expect(rig.history.canUndo, isFalse);
    expect(rig.history.canRedo, isTrue);

    await rig.history.redo();
    expect(rig.history.canUndo, isTrue);
    expect(rig.history.canRedo, isFalse);
  });

  test('a failed undo keeps its entry for a retry', () async {
    final rig = _Rig()..failing.add('a');
    rig.history.pushUndo('a');

    await rig.history.undo();

    expect(rig.history.canUndo, isTrue);
    expect(rig.history.canRedo, isFalse);
  });

  test(
    'an entry whose object is gone is dropped and the next one runs',
    () async {
      final rig = _Rig()..gone.add('b');
      rig.history
        ..pushUndo('a')
        ..pushUndo('b');

      await rig.history.undo();

      expect(rig.history.canUndo, isFalse);
      expect(rig.history.canRedo, isTrue);
    },
  );

  test('a fresh edit clears redo', () async {
    final rig = _Rig();
    rig.history.pushUndo('a');
    await rig.history.undo();

    rig.history.pushUndo('b');

    expect(rig.history.canRedo, isFalse);
  });

  test('only the newest undoStackDepth entries are kept', () async {
    final rig = _Rig();
    for (var i = 0; i < undoStackDepth + 5; i++) {
      rig.history.pushUndo('e$i');
    }
    var undone = 0;
    while (rig.history.canUndo) {
      await rig.history.undo();
      undone++;
    }

    expect(undone, undoStackDepth);
  });

  test('an undo that finds nothing left says so', () async {
    final rig = _Rig();
    rig.history.pushUndo('skip');

    await rig.history.undo();

    expect(rig.errors, ['Nothing left to undo is still on the board.']);
  });
}
