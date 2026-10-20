// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hand-pinned interleavings of what `canvas_engine_fuzz_test.dart` found,
/// one test per root cause, on the same engines and modelled server.
///
/// Each test states what a viewer should see and fails today. They run real
/// `CanvasEngine`s, so they cover the wiring (`fetch`, `_apply`, the live
/// dispatch) and not only `CanvasDocument` and `CanvasSync` alone.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_commit_queue.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_fuzz_checks.dart';
import '../../support/canvas_fuzz_script.dart';
import '../../support/canvas_fuzz_world.dart';

const _stroke = {
  'points': [0.0, 0.0, 40.0, 30.0],
  'width': 3.0,
  'color': 'annotation',
};

/// Two engines (me, a moderator) and a server, settled and empty.
void _scenario(
  void Function(FuzzWorld world, FuzzClient me, FuzzClient peer) body,
) {
  fakeAsync((async) {
    final world = FuzzWorld(1, async, FuzzConfig.calm);
    try {
      world.quiesce();
      body(world, world.clients[0], world.clients[1]);
    } finally {
      world.dispose();
    }
  });
}

int _copies(FuzzClient client, String id) =>
    gridLiveIds(client.engine.document).where((e) => e == id).length;

String _place(
  FuzzWorld world,
  String id, {
  String actor = 'ann',
  double x = 100,
  double y = 100,
}) {
  world.server.place(actor, id, 'stroke', x, y, 40, 30, Map.of(_stroke));
  return id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a restore frame that lands after a read already showing the object '
      'does not paint it twice', () {
    _scenario((world, me, peer) {
      _place(world, 'x');
      world.as_('mod', {'id': 'c1', 'kind': 'clear', 'before_seq': 1});
      // The catch-up is served between the clear and the restore.
      unawaited(me.engine.sync.catchUp());
      world.flush();
      final catchUp = world.waiting(
        me,
        (r) => r.url.path.endsWith('/canvas/ops'),
      );
      world.serverActs(me, catchUp);
      world.as_('mod', {'id': 'r1', 'kind': 'restore', 'target_op': 'c1'});
      world.replyArrives(me, catchUp);
      // A read taken after the restore shows the object, then the restore frame arrives.
      world.readBoard(me);
      world.deliverAllFrames(me);
      world.quiesce();

      expect(
        _copies(me, 'x'),
        1,
        reason:
            'the restore frame cleared the read-in object from the id table '
            'while it was live, so the next read placed a second copy that '
            'nothing can erase or move',
      );
    });
  });

  test('a committed move that reached a viewer through a catch-up settles the '
      'drag preview instead of letting it snap the object back', () {
    _scenario((world, me, peer) {
      _place(world, 's');
      world.quiesce();
      expect(me.engine.document.objectBounds('s')!.x, 100);

      // ann drags it: previews first, then the committed move.
      for (var i = 1; i <= 3; i++) {
        world.publishEphemeral(
          api.CanvasObjectPreview(
            channelId: fuzzChannel,
            userId: 'ann',
            objectId: 's',
            x: 100.0 + i * 100,
            y: 100,
            w: 40,
            h: 30,
            ended: i == 3,
          ),
        );
      }
      world.deliverAllFrames(me);
      world.as_('ann', {
        'id': 'm1',
        'kind': 'move',
        'object_id': 's',
        'x': 400.0,
        'y': 100.0,
        'w': 40.0,
        'h': 30.0,
      });
      // The live move frame is lost to this viewer; a catch-up carries it.
      world.loseFrames(me);
      unawaited(me.engine.sync.catchUp());
      world.flush();
      world.roundTrip(
        me,
        world.waiting(me, (r) => r.url.path.endsWith('/canvas/ops')),
      );
      expect(me.engine.document.objectBounds('s')!.x, 400);

      world.elapse(9000);
      expect(
        me.engine.document.objectBounds('s')!.x,
        400,
        reason:
            'the preview was never settled by the catch-up that applied the '
            'move, so it expired and moved the object back to where the drag began',
      );
    });
  });

  test('erasing, deleting or undoing an object another member has locked does '
      'not hide it on this client alone', () {
    _scenario((world, me, peer) {
      _place(world, 'mine', actor: 'me');
      world.quiesce();
      world.server.setLocked('mine', true);
      world.deliverAllFrames(me);

      unawaited(me.engine.ops.deleteSelected('mine'));
      world.flush();
      world.quiesce();

      expect(
        world.server.objects['mine']!.live,
        isTrue,
        reason: 'the server skips a locked object',
      );
      expect(
        me.engine.document.isAlive('mine'),
        isTrue,
        reason:
            'the remove answered affected=0 and the client ignored it, so '
            'the locked object stays hidden here while everyone else sees it',
      );
    });
  });

  test('a clear does not leave ink on a viewer whose read was in flight', () {
    _scenario((world, me, peer) {
      _place(world, 'old');
      world.quiesce();
      // ann draws something this viewer never hears about, then it reads the board.
      _place(world, 'late');
      world.loseFrames(me);
      unawaited(me.engine.fetch());
      world.flush();
      final read = world.waiting(
        me,
        (r) => r.url.path.endsWith('/canvas/objects') && r.method == 'GET',
      );
      world.serverActs(me, read);
      // The clear lands before the read's reply does.
      world.as_('mod', {
        'id': 'c1',
        'kind': 'clear',
        'before_seq': world.server.head,
      });
      world.deliverAllFrames(me);
      for (final p
          in me.pending
              .where(
                (p) => !p.arrived && p.request.url.path.endsWith('/canvas/ops'),
              )
              .toList()) {
        world.roundTrip(me, p);
      }
      world.replyArrives(me, read);
      world.quiesce();

      expect(world.server.liveObjects, isEmpty);
      expect(
        gridLiveIds(me.engine.document),
        isEmpty,
        reason:
            'the clear removed ids the client did not hold, so nothing '
            'tombstoned them and the late reply drew them back for good',
      );
    });
  });

  test('a read that was answered before a reorder does not undo the reorder '
      'when it lands', () {
    _scenario((world, me, peer) {
      _place(world, 'a');
      _place(world, 'b', x: 300);
      world.quiesce();
      unawaited(me.engine.fetch());
      world.flush();
      final read = world.waiting(
        me,
        (r) => r.url.path.endsWith('/canvas/objects') && r.method == 'GET',
      );
      world.serverActs(me, read);
      world.as_('ann', {
        'id': 'z1',
        'kind': 'reorder',
        'object_id': 'a',
        'z_index': 50,
      });
      world.deliverAllFrames(me);
      expect(me.engine.document.zIndexOf('a'), 50);
      world.replyArrives(me, read);
      world.quiesce();

      expect(
        me.engine.document.zIndexOf('a'),
        50,
        reason: 'the late read wrote the older z-index over the newer live one',
      );
    });
  });

  test('a slow catch-up page does not re-remove an object that was restored '
      'live while it was in flight', () {
    _scenario((world, me, peer) {
      _place(world, 'x');
      world.quiesce();
      world.as_('ann', {
        'id': 'rm',
        'kind': 'remove',
        'object_ids': ['x'],
      });
      unawaited(me.engine.sync.catchUp());
      world.flush();
      final slow = world.waiting(me, (r) => r.url.path.endsWith('/canvas/ops'));
      world.serverActs(me, slow);
      world.as_('ann', {'id': 'rs', 'kind': 'restore', 'target_op': 'rm'});
      world.deliverAllFrames(me);
      world.replyArrives(me, slow);
      world.quiesce();

      expect(world.server.objects['x']!.live, isTrue);
      expect(
        me.engine.document.isAlive('x'),
        isTrue,
        reason:
            'the page replayed the older remove after the newer restore had '
            'been applied live, and the cursor was already past the restore',
      );
    });
  });

  test('a slow catch-up page does not move an object back to where an older '
      'move put it', () {
    _scenario((world, me, peer) {
      _place(world, 'x');
      world.quiesce();
      world.as_('ann', {
        'id': 'm1',
        'kind': 'move',
        'object_id': 'x',
        'x': 200.0,
        'y': 100.0,
        'w': 40.0,
        'h': 30.0,
      });
      unawaited(me.engine.sync.catchUp());
      world.flush();
      final slow = world.waiting(me, (r) => r.url.path.endsWith('/canvas/ops'));
      world.serverActs(me, slow);
      world.as_('ann', {
        'id': 'm2',
        'kind': 'move',
        'object_id': 'x',
        'x': 300.0,
        'y': 100.0,
        'w': 40.0,
        'h': 30.0,
      });
      world.deliverAllFrames(me);
      world.replyArrives(me, slow);
      world.quiesce();

      expect(
        me.engine.document.objectBounds('x')!.x,
        300,
        reason: 'the older move was replayed over the newer live one',
      );
    });
  });

  test('a live frame that arrives while a catch-up is in flight, and is not '
      'in its page, is not lost on a canvas that then goes quiet', () {
    _scenario((world, me, peer) {
      _place(world, 'first');
      world.quiesce();
      _place(world, 'second');
      unawaited(me.engine.sync.catchUp());
      world.flush();
      final page = world.waiting(me, (r) => r.url.path.endsWith('/canvas/ops'));
      world.serverActs(me, page);
      // Placed after the page was served, and its frame beats both 'second' and the page.
      _place(world, 'third', x: 500);
      world.deliverSeq(me, 3);
      world.replyArrives(me, page);
      world.deliverAllFrames(me);
      world.quiesce();

      expect(world.server.liveObjects.length, 3);
      expect(
        gridLiveIds(me.engine.document).toSet(),
        {'first', 'second', 'third'},
        reason:
            'the frame was dropped as a gap while the catch-up ran, the page '
            'predated it, and nothing asks again until some later op arrives',
      );
    });
  });

  test('a note edit the server refuses rolls the note back to the text the '
      'server holds, even after two edits in a row', () {
    _scenario((world, me, peer) {
      world.server.place('mod', 'n', 'note', 100, 100, 200, 100, {
        'text': 'hello',
      });
      world.quiesce();

      unawaited(me.engine.ops.editNote('n', 'first try'));
      unawaited(me.engine.ops.editNote('n', 'second try'));
      world.flush();
      for (final p in me.pending.where((p) => !p.arrived).toList()) {
        world.roundTrip(me, p);
      }
      world.quiesce();

      expect(world.server.objects['n']!.props['text'], 'hello');
      expect(
        me.engine.document.noteTextOf('n'),
        'hello',
        reason:
            'each rollback restores the text seen when its own edit began, '
            'so the second one puts the first, refused, text back',
      );
    });
  });

  test('pressing Delete on an object that was just given up on does not send '
      'a remove the server cannot know', () {
    _scenario((world, me, peer) {
      // Two strokes in the commit queue: the first is on the wire, the second waits.
      const id = 'me-pending';
      final document = me.engine.document;
      for (final name in ['me-sending', id]) {
        document.applyPlaced(
          CanvasStrokeInput(
            id: name,
            seq: 0,
            zIndex: provisionalLocalZIndex,
            x: 10,
            y: 10,
            w: 20,
            h: 20,
            points: const [0, 0, 20, 20],
            width: 3,
            colorKey: 'annotation',
            authorId: 'me',
          ),
        );
        me.engine.commits.add(
          CanvasCommit(
            id: name,
            x: 10,
            y: 10,
            w: 20,
            h: 20,
            props: Map.of(_stroke),
          ),
        );
      }
      world.flush();
      document.selectedObjectId.value = id;

      unawaited(me.engine.ops.deleteSelected(id));
      world.flush();
      expect(
        document.selectedObjectId.value,
        isNull,
        reason: 'the object is gone, so nothing should stay selected',
      );
      final removes = me.pending.where(
        (p) =>
            p.request.url.path.endsWith('/canvas/ops') &&
            p.request.method == 'POST',
      );
      expect(removes, isEmpty);
    });
  });

  test('a stroke the server confirmed is not given up on because three '
      'replies were lost', () {
    _scenario((world, me, peer) {
      const id = 'me-s';
      me.engine.document.applyPlaced(
        const CanvasStrokeInput(
          id: id,
          seq: 0,
          zIndex: provisionalLocalZIndex,
          x: 10,
          y: 10,
          w: 40,
          h: 30,
          points: [0, 0, 40, 30],
          width: 3,
          colorKey: 'annotation',
          authorId: 'me',
        ),
      );
      me.engine.commits.add(
        CanvasCommit(
          id: id,
          x: 10,
          y: 10,
          w: 40,
          h: 30,
          props: Map.of(_stroke),
        ),
      );
      world.flush();
      // Every attempt reaches the server and every reply is lost, but the live frame arrives.
      for (var attempt = 0; attempt < 3; attempt++) {
        final post = world.waiting(
          me,
          (r) => r.method == 'POST' && r.url.path.endsWith('/canvas/objects'),
        );
        world.serverActs(me, post);
        if (attempt == 0) world.deliverAllFrames(me);
        world.replyLost(me, post);
        world.elapse(1000);
      }
      world.quiesce();

      expect(world.server.objects[id]!.live, isTrue);
      expect(
        me.engine.document.isAlive(id),
        isTrue,
        reason:
            'the commit queue gave up and killed a stroke the live frame had '
            'already confirmed, so the drawer loses sight of ink everyone else sees',
      );
    });
  });

  test('a second catch-up that needs a reset within five seconds of the first '
      'is not dropped on the floor', () {
    _scenario((world, me, peer) {
      void drain() {
        for (var i = 0; i < 6; i++) {
          for (final p in me.pending.where((p) => !p.arrived).toList()) {
            world.roundTrip(me, p);
          }
        }
      }

      world.server.resetGap = 3;
      for (var i = 0; i < 6; i++) {
        _place(world, 'a$i', x: 50.0 * i);
      }
      world.loseFrames(me);
      unawaited(me.engine.sync.catchUp());
      world.flush();
      drain();
      expect(gridLiveIds(me.engine.document).length, 6);

      // Moments later it falls behind again, by more than the server keeps.
      world.elapse(1000);
      for (var i = 0; i < 6; i++) {
        _place(world, 'b$i', x: 50.0 * i, y: 300);
      }
      world.loseFrames(me);
      unawaited(me.engine.sync.catchUp());
      world.flush();
      drain();
      world.elapse(20000);
      drain();

      expect(
        gridLiveIds(me.engine.document).length,
        12,
        reason:
            'the hard-reset floor swallowed the second reset and nothing '
            'schedules another attempt, so the viewer stays on the old '
            'picture until some later op happens to arrive',
      );
    });
  });

  test('re-reading the board repairs a viewer whose picture has drifted', () {
    _scenario((world, me, peer) {
      _place(world, 'real');
      world.quiesce();
      // A picture that has drifted for any reason: one stale box, one object the server no longer has.
      me.engine.document.moveObject('real', 700, 700, 40, 30);
      me.engine.document.applyPlaced(
        const CanvasStrokeInput(
          id: 'ghost',
          seq: 9,
          zIndex: 9,
          x: 300,
          y: 300,
          w: 20,
          h: 20,
          points: [0, 0, 20, 20],
          width: 3,
          colorKey: 'annotation',
        ),
      );

      world.readBoard(me);
      world.quiesce();

      expect(me.engine.document.objectBounds('real')!.x, 100);
      expect(
        me.engine.document.isAlive('ghost'),
        isFalse,
        reason:
            'a read answers for the whole region it covers, yet it only adds: '
            'it leaves a known object at its old box and keeps an object the '
            'read no longer lists, so only reopening the canvas repairs a drift',
      );
    });
  });
}
