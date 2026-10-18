// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [RemoteStrokeDrafts]: appending as a delta, `end`, prune-by-age, and
/// `clear` - the same shape `canvas_cursors_test.dart` already covers, plus
/// what is new here: accumulation across several frames.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  test('appendOrCreate starts a draft and notifies once', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    var notifications = 0;
    drafts.addListener(() => notifications++);

    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [1.0, 2.0],
      colorIndex: 0,
    );

    expect(drafts.all.single.objectId, 'd1');
    expect(drafts.all.single.points, [1.0, 2.0]);
    expect(notifications, 1);
  });

  test('a later frame for the same id appends to what it already holds', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);

    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [1.0, 2.0],
      colorIndex: 0,
    );
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [3.0, 4.0],
      colorIndex: 0,
    );

    expect(drafts.all.length, 1);
    expect(drafts.all.single.points, [1.0, 2.0, 3.0, 4.0]);
  });

  test('two distinct object ids are two independent drafts', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);

    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [1.0, 1.0],
      colorIndex: 0,
    );
    drafts.appendOrCreate(
      objectId: 'd2',
      authorId: 'bob',
      points: const [2.0, 2.0],
      colorIndex: 1,
    );

    expect(drafts.all.map((d) => d.objectId).toSet(), {'d1', 'd2'});
  });

  test('end drops one draft by id and is a silent no-op for an unknown one',
      () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [0.0, 0.0],
      colorIndex: 0,
    );

    var notifications = 0;
    drafts.addListener(() => notifications++);
    drafts.end('nobody');
    expect(notifications, 0, reason: 'ending an unknown id must not notify');

    drafts.end('d1');
    expect(drafts.all, isEmpty);
    expect(notifications, 1);
  });

  test('pruneOlderThan drops only drafts stale past the ttl', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    final base = DateTime(2026, 1, 1);

    drafts.appendOrCreate(
      objectId: 'stale',
      authorId: 'alice',
      points: const [0.0, 0.0],
      colorIndex: 0,
      now: base,
    );
    drafts.appendOrCreate(
      objectId: 'fresh',
      authorId: 'bob',
      points: const [0.0, 0.0],
      colorIndex: 1,
      now: base.add(const Duration(seconds: 5)),
    );

    drafts.pruneOlderThan(
      const Duration(seconds: 6),
      now: base.add(const Duration(seconds: 8)),
    );

    expect(drafts.all.map((d) => d.objectId), ['fresh']);
  });

  test(
    'pruneOlderThan is a no-op, and notifies nothing, when nothing is stale',
    () {
      final drafts = RemoteStrokeDrafts();
      addTearDown(drafts.dispose);
      final base = DateTime(2026, 1, 1);
      drafts.appendOrCreate(
        objectId: 'd1',
        authorId: 'alice',
        points: const [0.0, 0.0],
        colorIndex: 0,
        now: base,
      );

      var notifications = 0;
      drafts.addListener(() => notifications++);
      drafts.pruneOlderThan(
        const Duration(seconds: 10),
        now: base.add(const Duration(seconds: 1)),
      );

      expect(drafts.all.length, 1);
      expect(notifications, 0);
    },
  );

  test('a later frame refreshes the staleness clock for that id', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    final base = DateTime(2026, 1, 1);

    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [0.0, 0.0],
      colorIndex: 0,
      now: base,
    );
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [1.0, 1.0],
      colorIndex: 0,
      now: base.add(const Duration(seconds: 5)),
    );

    drafts.pruneOlderThan(
      const Duration(seconds: 6),
      now: base.add(const Duration(seconds: 8)),
    );

    expect(drafts.all, isNotEmpty, reason: 'the refresh at 5s must count');
  });

  test(
    'accumulated points are capped, keeping the most recent and dropping the oldest',
    () {
      final drafts = RemoteStrokeDrafts();
      addTearDown(drafts.dispose);

      // A peer refreshing one draft forever must not grow this without bound.
      for (var i = 0; i < maxDraftPreviewPoints + 500; i++) {
        drafts.appendOrCreate(
          objectId: 'd1',
          authorId: 'alice',
          points: [i.toDouble(), i.toDouble()],
          colorIndex: 0,
        );
      }

      final points = drafts.all.single.points;
      expect(points.length, maxDraftPreviewPoints * 2);
      // The oldest points (low indices) are the ones dropped.
      expect(points.first, 500.0);
      expect(points.last, (maxDraftPreviewPoints + 499).toDouble());
    },
  );

  test('clear drops every draft at once', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [0.0, 0.0],
      colorIndex: 0,
    );
    drafts.appendOrCreate(
      objectId: 'd2',
      authorId: 'bob',
      points: const [1.0, 1.0],
      colorIndex: 1,
    );

    drafts.clear();

    expect(drafts.all, isEmpty);
  });

  test('a finished draft stays painted until its committed stroke arrives', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [0.0, 0.0, 5.0, 5.0],
      colorIndex: 0,
    );

    drafts.finish('d1');
    expect(drafts.all.single.ended, isTrue);
    expect(drafts.all.single.points, [0.0, 0.0, 5.0, 5.0]);

    drafts.settleAuthor('bob');
    expect(drafts.all, hasLength(1),
        reason: 'another author must not settle it');
    drafts.settleAuthor('alice');
    expect(drafts.all, isEmpty);
  });

  test('a finished draft that never commits is dropped after the grace', () {
    final drafts = RemoteStrokeDrafts();
    addTearDown(drafts.dispose);
    final base = DateTime(2026, 1, 1);
    drafts.appendOrCreate(
      objectId: 'd1',
      authorId: 'alice',
      points: const [0.0, 0.0],
      colorIndex: 0,
      now: base,
    );
    drafts.finish('d1', now: base);

    drafts.pruneOlderThan(const Duration(seconds: 6),
        now: base.add(const Duration(seconds: 1)));
    expect(drafts.all, hasLength(1));
    drafts.pruneOlderThan(const Duration(seconds: 6),
        now: base.add(finishedDraftGrace + const Duration(milliseconds: 1)));
    expect(drafts.all, isEmpty);
  });
}
