// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Moving several picked objects at once: who goes along, where the group stops, and what a refusal leaves.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import '../../support/canvas_ops_rig.dart';

CanvasStrokeInput _note(String id, double x, {String authorId = 'me'}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: 100,
      w: 100,
      h: 100,
      points: const [],
      width: 0,
      colorKey: '',
      authorId: authorId,
      kind: CanvasObjectKind.note,
      text: 'n',
    );

class _Rig {
  _Rig({this.failOn = 0, Set<String> locked = const {}}) {
    document = CanvasDocument()
      ..setViewport(const Size(800, 600))
      ..setBoard(canvasBoard);
    final api.SlimmApi client = testApi((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      if (failOn != 0 && requests.length == failOn) {
        return http.Response('{}', 500);
      }
      return acceptedOp(n: requests.length, kind: 'move', affected: 1);
    });
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: plainCommitQueue(client),
      onError: errors.add,
      isLocked: locked.contains,
    );
  }

  final int failOn;
  late final CanvasDocument document;
  late final CanvasOpsController ops;
  final requests = <Map<String, dynamic>>[];
  final errors = <String>[];

  void place(CanvasStrokeInput input) => document
    ..applyPlaced(input)
    ..refresh();

  bool grab(Iterable<String> ids) =>
      ops.beginGroupDrag(Offset.zero, ids, manageCanvas: false, selfId: 'me');

  Future<void> dragBy(double dx, double dy) async {
    ops.dragSelect(Offset(dx, dy), lockAspect: false);
    await ops.endSelect();
  }
}

void main() {
  test('every picked object moves by the same step, as one undo', () async {
    final rig = _Rig()
      ..place(_note('a', 100))
      ..place(_note('b', 300));
    expect(rig.grab(['a', 'b']), isTrue);

    await rig.dragBy(40, 20);

    expect(rig.document.objectBounds('a')!.x, 140);
    expect(rig.document.objectBounds('b')!.x, 340);
    expect(rig.document.objectBounds('b')!.y, 120);
    expect(rig.requests.map((r) => r['object_id']), ['a', 'b']);
    await rig.ops.undo();
    expect(rig.document.objectBounds('a')!.x, 100);
    expect(rig.document.objectBounds('b')!.x, 300);
    expect(rig.ops.canUndo, isFalse);
  });

  test('a locked or foreign object stays put while the rest move', () async {
    final rig = _Rig(locked: {'b'})
      ..place(_note('a', 100))
      ..place(_note('b', 300))
      ..place(_note('c', 500, authorId: 'other'));

    expect(rig.grab(['a', 'b', 'c']), isTrue);
    await rig.dragBy(40, 0);

    expect(rig.document.objectBounds('a')!.x, 140);
    expect(rig.document.objectBounds('b')!.x, 300);
    expect(rig.document.objectBounds('c')!.x, 500);
    expect(rig.requests, hasLength(1));
  });

  test('a group of objects none of which may move picks nothing up', () {
    final rig = _Rig(locked: {'a'})..place(_note('a', 100));

    expect(rig.grab(['a']), isFalse);
  });

  test(
    'the group stops at the board edge without squeezing together',
    () async {
      final rig = _Rig()
        ..place(_note('a', 100))
        ..place(_note('b', 300));
      rig.grab(['a', 'b']);

      await rig.dragBy(-5000, 0);

      final a = rig.document.objectBounds('a')!;
      final b = rig.document.objectBounds('b')!;
      expect(a.x, canvasBoard.left);
      expect(b.x - a.x, 200);
    },
  );

  test(
    'a refusal puts back what had not been sent, and keeps the rest undoable',
    () async {
      final rig = _Rig(failOn: 2)
        ..place(_note('a', 100))
        ..place(_note('b', 300))
        ..place(_note('c', 500));
      rig.grab(['a', 'b', 'c']);

      await rig.dragBy(40, 0);

      expect(rig.document.objectBounds('a')!.x, 140);
      expect(rig.document.objectBounds('b')!.x, 300);
      expect(rig.document.objectBounds('c')!.x, 500);
      expect(rig.errors, isNotEmpty);
      expect(rig.ops.canUndo, isTrue);
    },
  );

  test('cancelling a group drag puts every object back', () {
    final rig = _Rig()
      ..place(_note('a', 100))
      ..place(_note('b', 300));
    rig.grab(['a', 'b']);
    rig.ops.dragSelect(const Offset(60, 60), lockAspect: false);

    rig.ops.cancelSelect();

    expect(rig.document.objectBounds('a')!.x, 100);
    expect(rig.document.objectBounds('b')!.x, 300);
    expect(rig.requests, isEmpty);
  });
}
