// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasActivityLog]: recording ops and live events into entries, the
/// blocked-author filter, bounded capacity, and the throttled announcement
/// batch - plus the sentence builders that turn an entry into text.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';

api.CanvasObject _object({
  String id = 'obj-1',
  String kind = 'stroke',
  String? authorId = 'alice',
  Map<String, dynamic> props = const {},
}) => api.CanvasObject(
  id: id,
  kind: kind,
  zIndex: 1,
  x: 0,
  y: 0,
  w: 1,
  h: 1,
  props: props,
  authorId: authorId,
  seq: 1,
  createdAt: 0,
);

void main() {
  group('recordOp', () {
    test('a place op carries its own actor and object kind', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        api.CanvasPlaceOp(
          seq: 1,
          id: 'op-1',
          actorId: 'alice',
          createdAt: 0,
          object: _object(kind: 'image'),
        ),
      );

      final entry = log.entries.single;
      expect(entry.kind, CanvasActivityKind.placed);
      expect(entry.actorId, 'alice');
      expect(entry.objectKind, 'image');
    });

    test('a note carries its own text into the entry, truncated past 80', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        api.CanvasPlaceOp(
          seq: 1,
          id: 'op-note',
          actorId: 'alice',
          createdAt: 0,
          object: _object(kind: 'note', props: {'text': 'a' * 90}),
        ),
      );

      final entry = log.entries.single;
      expect(entry.objectKind, 'note');
      expect(entry.detail, hasLength(81));
      expect(entry.detail, endsWith('…'));
    });

    test('a shape and a plain stroke both carry no detail', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        api.CanvasPlaceOp(
          seq: 1,
          id: 'op-shape',
          actorId: 'alice',
          createdAt: 0,
          object: _object(kind: 'shape'),
        ),
      );

      expect(log.entries.single.detail, isNull);
    });

    test('a remove op carries the count and whatever actor the wire sent', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasRemoveOp(
          seq: 2,
          id: 'op-2',
          actorId: null,
          createdAt: 0,
          objectIds: ['a', 'b', 'c'],
        ),
      );

      final entry = log.entries.single;
      expect(entry.kind, CanvasActivityKind.removed);
      expect(entry.actorId, isNull);
      expect(entry.count, 3);
    });

    test(
      'a null actor on a moderation op is never treated as unknown-ask-again',
      () {
        final log = CanvasActivityLog(isBlocked: (_) => false);
        addTearDown(log.dispose);

        log.recordOp(
          const api.CanvasClearOp(
            seq: 3,
            id: 'op-3',
            actorId: null,
            createdAt: 0,
            beforeSeq: 10,
          ),
        );

        expect(log.entries.single.actorId, isNull);
        expect(
          describeCanvasActivityEntry(log.entries.single),
          'The canvas was cleared.',
          reason: 'no "someone" invented for a withheld moderation actor',
        );
      },
    );

    test('a move op with a disclosed actor (MANAGE_CANVAS) keeps it', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasMoveOp(
          seq: 4,
          id: 'op-4',
          actorId: 'mod',
          createdAt: 0,
          objectId: 'x',
          x: 0,
          y: 0,
          w: 1,
          h: 1,
        ),
      );

      expect(log.entries.single.actorId, 'mod');
    });

    test('a restore op carries its own object count', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasRestoreOp(
          seq: 5,
          id: 'op-5',
          actorId: 'mod',
          createdAt: 0,
          targetOp: 'op-2',
          objectIds: ['a', 'b'],
        ),
      );

      expect(log.entries.single.kind, CanvasActivityKind.restored);
      expect(log.entries.single.count, 2);
    });

    test('a reorder op with a disclosed actor (MANAGE_CANVAS) keeps it', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasReorderOp(
          seq: 7,
          id: 'op-7',
          actorId: 'mod',
          createdAt: 0,
          objectId: 'x',
          zIndex: 42,
        ),
      );

      expect(log.entries.single.kind, CanvasActivityKind.reordered);
      expect(log.entries.single.actorId, 'mod');
    });

    test('an edit op records as an edit and keeps its disclosed actor', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasEditOp(
          seq: 8,
          id: 'op-8',
          actorId: 'mod',
          createdAt: 0,
          objectId: 'x',
          props: {'text': 'new'},
        ),
      );

      expect(log.entries.single.kind, CanvasActivityKind.edited);
      expect(log.entries.single.actorId, 'mod');
      expect(
        describeCanvasActivityEntry(log.entries.single, nameFor: (_) => 'Maya'),
        'Maya edited a note.',
      );
    });

    test('an unknown op kind is not recorded at all', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasUnknownOp(
          seq: 6,
          id: 'op-6',
          actorId: null,
          createdAt: 0,
        ),
      );

      expect(log.entries, isEmpty);
    });
  });

  group('live recording', () {
    test('a live placement carries its actor - the one live kind that ever '
        'does', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log.recordPlacedLive(_object(authorId: 'alice'));

      expect(log.entries.single.actorId, 'alice');
    });

    test('a live removal, clear, restore, move or reorder never carries an '
        'actor - the live frame structurally has none', () {
      final log = CanvasActivityLog(isBlocked: (_) => false);
      addTearDown(log.dispose);

      log
        ..recordRemovedLive('op-1', ['a', 'b'])
        ..recordClearedLive('op-2')
        ..recordRestoredLive('op-3', 2)
        ..recordMovedLive('op-4')
        ..recordReorderedLive('op-5');

      expect(log.entries.map((e) => e.actorId), everyElement(isNull));
      expect(log.entries.map((e) => e.kind), [
        CanvasActivityKind.removed,
        CanvasActivityKind.cleared,
        CanvasActivityKind.restored,
        CanvasActivityKind.moved,
        CanvasActivityKind.reordered,
      ]);
    });
  });

  test('a hard reset records a resync entry with no actor', () {
    final log = CanvasActivityLog(isBlocked: (_) => false);
    addTearDown(log.dispose);

    log.recordResync();

    expect(log.entries.single.kind, CanvasActivityKind.resynced);
    expect(log.entries.single.actorId, isNull);
  });

  test('a blocked author\'s placement never reaches the list', () {
    final log = CanvasActivityLog(isBlocked: (id) => id == 'blocked');
    addTearDown(log.dispose);

    log.recordPlacedLive(_object(authorId: 'blocked'));
    log.recordPlacedLive(_object(id: 'obj-2', authorId: 'alice'));

    expect(log.entries, hasLength(1));
    expect(log.entries.single.actorId, 'alice');
  });

  test(
    'a blocked moderator\'s disclosed removal never reaches the list either',
    () {
      final log = CanvasActivityLog(isBlocked: (id) => id == 'blocked-mod');
      addTearDown(log.dispose);

      log.recordOp(
        const api.CanvasRemoveOp(
          seq: 1,
          id: 'op-1',
          actorId: 'blocked-mod',
          createdAt: 0,
          objectIds: ['a'],
        ),
      );

      expect(log.entries, isEmpty);
    },
  );

  test('an entry with no actor is never filtered by blocking', () {
    final log = CanvasActivityLog(isBlocked: (_) => true);
    addTearDown(log.dispose);

    log.recordClearedLive('op-1');

    expect(
      log.entries,
      hasLength(1),
      reason: 'nothing to match a blocked id against',
    );
  });

  test('the list is bounded, oldest entries evicted first', () {
    final log = CanvasActivityLog(isBlocked: (_) => false, capacity: 3);
    addTearDown(log.dispose);

    for (var i = 0; i < 5; i++) {
      log.recordPlacedLive(_object(id: 'obj-$i'));
    }

    expect(log.entries.map((e) => e.id), ['obj-2', 'obj-3', 'obj-4']);
  });

  test('a burst of changes inside the throttle window announces once, not once '
      'per change', () {
    fakeAsync((async) {
      final log = CanvasActivityLog(
        isBlocked: (_) => false,
        announceDelay: const Duration(seconds: 2),
      );
      addTearDown(log.dispose);

      log.recordPlacedLive(_object(id: 'a'));
      async.elapse(const Duration(seconds: 1));
      log.recordPlacedLive(_object(id: 'b'));
      expect(
        log.announcementTick,
        0,
        reason: 'inside the throttle window, so no flush yet',
      );

      async.elapse(const Duration(seconds: 1, milliseconds: 1));
      expect(log.announcementTick, 1);

      final batch = log.takeAnnouncementBatch();
      expect(batch, hasLength(2));
      expect(log.takeAnnouncementBatch(), isEmpty);
    });
  });
}
