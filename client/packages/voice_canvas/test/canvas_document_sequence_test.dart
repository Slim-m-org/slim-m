// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a document keeps its books when snapshots, late replies and removals
/// reach it in any order.
library;

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput stroke(
  String id, {
  int seq = 1,
  double x = 0,
  int z = 1,
  CanvasObjectKind kind = CanvasObjectKind.stroke,
  String? text,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq,
      zIndex: z,
      x: x,
      y: 0,
      w: 10,
      h: 10,
      points: kind == CanvasObjectKind.stroke ? const [0, 0, 10, 10] : const [],
      width: 3,
      colorKey: 'annotation',
      kind: kind,
      text: text,
    );

CanvasDocument _document() =>
    CanvasDocument()..setViewport(const Size(800, 600));

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 1, 1),
    ui.Paint(),
  );
  return recorder.endRecording().toImage(1, 1);
}

void main() {
  group('snapshots', () {
    test('overwrite the box and text a document had wrong', () {
      final document = _document()
        ..applyPlaced(
          stroke('n', kind: CanvasObjectKind.note, text: 'old'),
        );

      document.applyPlaced(
        stroke('n', x: 90, kind: CanvasObjectKind.note, text: 'new'),
        overwrite: true,
      );

      expect(document.objectBounds('n')!.x, 90);
      expect(document.noteTextOf('n'), 'new');
    });

    test('leave an object being dragged where the pointer has it', () {
      final document = _document()..applyPlaced(stroke('a'));
      document.elevatedObjectId.value = 'a';
      document.moveObject('a', 33, 0, 10, 10);

      document.applyPlaced(stroke('a', x: 90), overwrite: true);

      expect(document.objectBounds('a')!.x, 33);
    });

    test('bring back an object removed before the snapshot was taken', () {
      final document = _document()..applyPlaced(stroke('a'));
      document.removeObject('a', seq: 8);

      expect(document.applyPlaced(stroke('a'), overwrite: true), isNull);
      expect(
        document.applyPlaced(stroke('a'), overwrite: true, snapshotSeq: 7),
        isNull,
        reason: 'a snapshot older than the removal cannot speak for it',
      );
      expect(
        document.applyPlaced(stroke('a'), overwrite: true, snapshotSeq: 9),
        isNotNull,
        reason: 'listed after the removal means restored since',
      );
      expect(document.isAlive('a'), isTrue);
    });

    test('never lift a removal whose seq is not known yet', () {
      final document = _document()..applyPlaced(stroke('a'));
      document.removeObject('a');

      expect(
        document.applyPlaced(stroke('a'), overwrite: true, snapshotSeq: 99),
        isNull,
      );

      document.confirmRemoved(['a'], 5);
      expect(
        document.applyPlaced(stroke('a'), overwrite: true, snapshotSeq: 99),
        isNotNull,
      );
    });

    test('a repeated placement reply cannot undo a reorder after it', () {
      final document = _document()..applyPlaced(stroke('a', seq: 4, z: 4));
      document.setZIndex('a', 9);

      document.applyPlaced(stroke('a', seq: 4, z: 4));

      expect(document.zIndexOf('a'), 9);
    });
  });

  group('the reflected seq', () {
    test('refuses a late placement of something already gone', () {
      final document = _document()..reflectedSeq = 10;

      expect(document.applyPlaced(stroke('late', seq: 7)), isNull);
      expect(document.applyPlaced(stroke('new', seq: 11)), isNotNull);
      expect(document.applyPlaced(stroke('mine', seq: 0)), isNotNull);
    });

    test('lets a snapshot add what it lists', () {
      final document = _document()..reflectedSeq = 10;

      expect(
        document.applyPlaced(stroke('far', seq: 3), overwrite: true),
        isNotNull,
      );
    });
  });

  group('bookkeeping', () {
    test('a killed stroke gives up the selection and the elevation', () {
      final document = _document()..applyPlaced(stroke('a'));
      document.selectedObjectId.value = 'a';
      document.elevatedObjectId.value = 'a';

      document.kill('a');

      expect(document.selectedObjectId.value, isNull);
      expect(document.elevatedObjectId.value, isNull);
    });

    test('a killed stroke removed afterwards is counted out once', () {
      final document = _document()
        ..applyPlaced(stroke('a'))
        ..applyPlaced(stroke('b', seq: 2));

      document
        ..kill('a')
        ..removeObject('a');

      expect(document.objectCount.value, 1);
    });

    test('a revived stroke is tracked against the board again', () {
      final document = _document()
        ..setBoard(const Rect.fromLTWH(0, 0, 100, 100));
      document.applyPlaced(stroke('out', x: 500));
      expect(document.outsideBoardCount.value, 1);

      document.kill('out');
      expect(document.outsideBoardCount.value, 0);
      document.applyPlaced(stroke('out', x: 500));

      expect(document.outsideBoardCount.value, 1);
    });

    test('a reset repaints and drops the selection', () {
      final document = _document()..applyPlaced(stroke('a'));
      document.selectedObjectId.value = 'a';
      var repaints = 0;
      document.addListener(() => repaints++);

      document.reset();

      expect(repaints, 1);
      expect(document.selectedObjectId.value, isNull);
    });

    test('a dropped object can be placed again', () {
      final document = _document()..applyPlaced(stroke('a'));

      document.dropObjects(['a']);

      expect(document.knows('a'), isFalse);
      expect(document.applyPlaced(stroke('a')), isNotNull);
    });

    test('a restore keeps a killed stroke addressable too', () {
      final document = _document()..applyPlaced(stroke('a'));
      document.kill('a');

      document.forgetRemoved(['a']);

      expect(document.knows('a'), isTrue);
    });
  });

  testWidgets('attaching a second bitmap frees the first', (tester) async {
    final first = (await tester.runAsync(_image))!;
    final second = (await tester.runAsync(_image))!;
    final document = _document()
      ..applyPlaced(
        stroke('i', kind: CanvasObjectKind.image).copyWithAttachment('att'),
      );

    document
      ..setImageBitmap('i', first)
      ..setImageBitmap('i', second);

    expect(first.debugDisposed, isTrue);
    expect(second.debugDisposed, isFalse);
    document.dispose();
  });
}

extension on CanvasStrokeInput {
  CanvasStrokeInput copyWithAttachment(String attachment) => CanvasStrokeInput(
        id: id,
        seq: seq,
        zIndex: zIndex,
        x: x,
        y: y,
        w: w,
        h: h,
        points: points,
        width: width,
        colorKey: colorKey,
        kind: kind,
        attachmentId: attachment,
      );
}
