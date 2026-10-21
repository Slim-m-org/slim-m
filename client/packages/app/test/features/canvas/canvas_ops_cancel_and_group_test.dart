// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A cancelled erase or drag undoes itself without a request, and the pieces
/// of one long stroke are erased and deleted together.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import '../../support/canvas_ops_rig.dart';
import '../../support/canvas_purge_fake.dart';

CanvasStrokeInput _piece(String id, double x, {String? group}) =>
    CanvasStrokeInput(
      id: id,
      seq: 1,
      zIndex: 1,
      x: x,
      y: 0,
      w: 100,
      h: 0,
      points: const [0, 0, 100, 0],
      width: 3,
      colorKey: 'annotation',
      authorId: 'me',
      groupId: group,
    );

class _Rig {
  _Rig() {
    final api.SlimmApi client = testApi((request) async {
      if (isPurge(request)) {
        final id = request.url.pathSegments.last;
        return fakePurge(request, {id}, purged: purges);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      return acceptedOp(
        n: requests.length,
        kind: body['kind'],
        affected: 1,
        status: 201,
      );
    });
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: plainCommitQueue(client),
      onError: (_) {},
      onRemoveFailed: () async => refetches++,
    );
  }

  final document = CanvasDocument()..setViewport(const Size(800, 600));
  final requests = <Map<String, dynamic>>[];
  final purges = <String>[];
  late final CanvasOpsController ops;
  int refetches = 0;
}

void main() {
  test('a cancelled erase sends nothing and re-reads what it hid', () async {
    final rig = _Rig();
    rig.document
      ..applyPlaced(_piece('a', 0))
      ..refresh();

    rig.ops.onErasePoint(
      const Offset(50, 0),
      manageCanvas: false,
      selfId: 'me',
    );
    expect(rig.document.isAlive('a'), isFalse);
    rig.ops.cancelErase();
    await rig.ops.endErase();

    expect(rig.requests, isEmpty);
    expect(rig.refetches, 1);
    rig.document.applyPlaced(_piece('a', 0));
    expect(rig.document.isAlive('a'), isTrue, reason: 'it may land again');
  });

  test('a cancelled drag puts the object back and sends nothing', () async {
    final rig = _Rig();
    rig.document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'n',
          seq: 1,
          zIndex: 1,
          x: 100,
          y: 100,
          w: 100,
          h: 60,
          points: [],
          width: 0,
          colorKey: 'note',
          authorId: 'me',
          kind: CanvasObjectKind.note,
          text: 'hi',
        ),
      )
      ..refresh();

    rig.ops.beginSelect(
      const Offset(150, 130),
      manageCanvas: false,
      selfId: 'me',
    );
    rig.ops.dragSelect(const Offset(300, 300), lockAspect: true);
    expect(rig.document.objectBounds('n')!.x, isNot(100));
    final restored = rig.ops.cancelSelect();
    await rig.ops.endSelect();

    expect(restored?.id, 'n');
    expect(rig.document.objectBounds('n')!.x, 100);
    expect(rig.document.objectBounds('n')!.y, 100);
    expect(rig.document.elevatedObjectId.value, isNull);
    expect(rig.requests, isEmpty);
  });

  test('touching one piece of a long stroke erases the whole mark', () async {
    final rig = _Rig();
    rig.document
      ..applyPlaced(_piece('a', 0, group: 'g'))
      ..applyPlaced(_piece('b', 100, group: 'g'))
      ..applyPlaced(_piece('other', 300))
      ..refresh();

    rig.ops.onErasePoint(
      const Offset(50, 0),
      manageCanvas: false,
      selfId: 'me',
    );
    await rig.ops.endErase();

    expect(rig.document.isAlive('a'), isFalse);
    expect(rig.document.isAlive('b'), isFalse);
    expect(rig.requests.single['object_ids'], unorderedEquals(['a', 'b']));
  });

  test('a locked piece stays, and so does the rest of the plan', () async {
    final rig = _Rig();
    rig.document
      ..applyPlaced(_piece('a', 0, group: 'g'))
      ..applyPlaced(_piece('b', 100, group: 'g'))
      ..refresh();
    final locked = CanvasOpsController(
      channelId: 'c1',
      client: rig.ops.client,
      document: rig.document,
      commits: rig.ops.commits,
      onError: (_) {},
      isLocked: (id) => id == 'b',
    );

    locked.onErasePoint(const Offset(50, 0), manageCanvas: false, selfId: 'me');
    await locked.endErase();

    expect(rig.document.isAlive('a'), isFalse);
    expect(rig.document.isAlive('b'), isTrue);
  });

  test('deleting one piece deletes the whole mark for good', () async {
    final rig = _Rig();
    rig.document
      ..applyPlaced(_piece('a', 0, group: 'g'))
      ..applyPlaced(_piece('b', 100, group: 'g'))
      ..refresh();

    await rig.ops.deleteSelected('a');

    expect(rig.document.isAlive('b'), isFalse);
    expect(rig.purges, unorderedEquals(['a', 'b']));
    expect(rig.requests, isEmpty);
    expect(rig.ops.canUndo, isTrue);
  });

  test(
    'a drag across more strokes than one op can carry goes out in several',
    () async {
      final rig = _Rig();
      for (var i = 0; i < maxRemoveIdsPerOp + 6; i++) {
        rig.document.applyPlaced(_piece('s$i', i * 150.0));
      }
      rig.document.refresh();

      for (var i = 0; i < maxRemoveIdsPerOp + 6; i++) {
        rig.ops.onErasePoint(
          Offset(i * 150.0 + 50, 0),
          manageCanvas: false,
          selfId: 'me',
        );
      }
      await rig.ops.endErase();
      await Future<void>.delayed(Duration.zero);

      final sent = [
        for (final r in rig.requests)
          ...(r['object_ids'] as List).cast<String>(),
      ];
      expect(sent.toSet(), hasLength(maxRemoveIdsPerOp + 6));
    },
  );
}
