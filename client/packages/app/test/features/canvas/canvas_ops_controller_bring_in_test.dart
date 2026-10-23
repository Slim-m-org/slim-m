// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bringing legacy off-board content back onto the board: who it may move,
/// where it stops on a refusal, and that undo puts it back. Decision 0080.
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

CanvasStrokeInput _shape(String id, double x, {String? authorId = 'me'}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: 0,
      w: 300,
      h: 200,
      points: const [],
      width: 0,
      colorKey: '',
      authorId: authorId,
      kind: CanvasObjectKind.shape,
      shapeKind: CanvasShapeKind.rectangle,
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

  void place(String id, double x, {String? authorId = 'me'}) => document
    ..applyPlaced(_shape(id, x, authorId: authorId))
    ..refresh();
}

void main() {
  test(
    'it moves what the caller placed and a later undo puts it back',
    () async {
      final rig = _Rig()..place('far', 2800);

      final result = await rig.ops.bringIntoBoard(
        manageCanvas: false,
        selfId: 'me',
      );

      expect(result.moved, 1);
      expect(
        rig.document.objectBounds('far')!.x + 300,
        lessThanOrEqualTo(canvasBoard.right),
      );
      expect(rig.ops.canUndo, isTrue);
    },
  );

  test(
    'it leaves another member\'s object alone without manage rights',
    () async {
      final rig = _Rig()..place('theirs', 2800, authorId: 'them');

      final result = await rig.ops.bringIntoBoard(
        manageCanvas: false,
        selfId: 'me',
      );

      expect(result.moved, 0);
      expect(rig.requests, isEmpty);
    },
  );

  test('an unknown caller is never taken for an unknown author', () async {
    final rig = _Rig()..place('orphan', 2800, authorId: null);

    final result = await rig.ops.bringIntoBoard(
      manageCanvas: false,
      selfId: null,
    );

    expect(result.moved, 0);
    expect(rig.requests, isEmpty);
  });

  test('it leaves a locked object alone even with manage rights', () async {
    final rig = _Rig(locked: {'far'})..place('far', 2800);

    final result = await rig.ops.bringIntoBoard(
      manageCanvas: true,
      selfId: 'me',
    );

    expect(result.moved, 0);
    expect(rig.requests, isEmpty);
  });

  test('it stops at the first refusal and tells the viewer once', () async {
    final rig = _Rig(failOn: 1)
      ..place('a', 2800)
      ..place('b', 2850)
      ..place('c', 2900);

    final result = await rig.ops.bringIntoBoard(
      manageCanvas: false,
      selfId: 'me',
    );

    expect(result.failed, isTrue);
    expect(result.moved, 0);
    expect(rig.requests, hasLength(1));
    expect(rig.errors, hasLength(1));
    expect(rig.document.objectBounds('a')!.x, 2800, reason: 'rolled back');
  });

  test(
    'dragging an object larger than the board commits the size it shows',
    () async {
      final rig = _Rig();
      rig.document
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'huge',
            seq: 1,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 5000,
            h: 3000,
            points: [],
            width: 0,
            colorKey: '',
            authorId: 'me',
            kind: CanvasObjectKind.shape,
            shapeKind: CanvasShapeKind.rectangle,
          ),
        )
        ..refresh();

      rig.ops.beginSelect(
        const Offset(0, 100),
        manageCanvas: false,
        selfId: 'me',
      );
      rig.ops.dragSelect(const Offset(10, 110), lockAspect: true);
      await rig.ops.endSelect();

      final shown = rig.document.objectBounds('huge')!;
      expect(shown.w, lessThanOrEqualTo(canvasBoard.width));
      expect(rig.requests.single['w'], shown.w);
      expect(rig.requests.single['h'], shown.h);
    },
  );
}
