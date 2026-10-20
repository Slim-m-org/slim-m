// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sentence builders [describeCanvasActivityEntry] and
/// [summarizeCanvasActivity]: one entry read aloud or in the panel, and a
/// throttled batch collapsed into one line.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CanvasClearScope;
import 'package:slimm_app/src/features/canvas/screens/canvas_activity_log.dart';

CanvasActivityEntry _entry({
  String id = 'e1',
  CanvasActivityKind kind = CanvasActivityKind.placed,
  String? actorId,
  String? objectKind,
  String? detail,
  int count = 1,
  CanvasClearScope? clearScope,
}) => CanvasActivityEntry(
  id: id,
  kind: kind,
  actorId: actorId,
  objectKind: objectKind,
  detail: detail,
  count: count,
  clearScope: clearScope,
  at: DateTime(2026),
);

void main() {
  group('describeCanvasActivityEntry', () {
    test('a scoped clear is not called a full clear', () {
      String say(CanvasClearScope scope, {String? actor = 'alice'}) =>
          describeCanvasActivityEntry(
            _entry(
              kind: CanvasActivityKind.cleared,
              actorId: actor,
              clearScope: scope,
            ),
            nameFor: (_) => 'Alice',
          );

      expect(
        say(const CanvasClearScope(kinds: ['image'])),
        'Alice cleared the images.',
      );
      expect(
        say(const CanvasClearScope(kinds: ['note', 'shape'])),
        'Alice cleared the notes, shapes.',
      );
      expect(
        say(const CanvasClearScope(authorId: 'bob')),
        "Alice cleared one person's content.",
      );
      expect(
        say(const CanvasClearScope(kinds: ['stroke']), actor: null),
        'Part of the canvas was cleared.',
      );
      expect(say(CanvasClearScope.everything), 'Alice cleared the canvas.');
    });

    test('a named placement names the drawer and the kind', () {
      expect(
        describeCanvasActivityEntry(
          _entry(actorId: 'alice', objectKind: 'stroke'),
          nameFor: (_) => 'Alice',
        ),
        'Alice placed a stroke.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(actorId: 'alice', objectKind: 'image'),
          nameFor: (_) => 'Alice',
        ),
        'Alice placed an image.',
      );
    });

    test('a shape names itself; a note names itself and its own text', () {
      expect(
        describeCanvasActivityEntry(
          _entry(actorId: 'alice', objectKind: 'shape'),
          nameFor: (_) => 'Alice',
        ),
        'Alice placed a shape.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(actorId: 'alice', objectKind: 'note', detail: 'buy milk'),
          nameFor: (_) => 'Alice',
        ),
        'Alice placed a note: buy milk.',
      );
    });

    test('an unresolved actor id falls back to "Someone", never blank', () {
      expect(
        describeCanvasActivityEntry(
          _entry(actorId: 'alice', objectKind: 'stroke'),
          nameFor: (_) => null,
        ),
        'Someone placed a stroke.',
      );
    });

    test('a withheld actor on a moderation kind never says "someone" - it '
        'is passive, not anonymous', () {
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.removed, actorId: null, count: 1),
        ),
        'An object was removed.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.removed, actorId: null, count: 3),
        ),
        '3 objects were removed.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.cleared, actorId: null),
        ),
        'The canvas was cleared.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.moved, actorId: null),
        ),
        'An object was moved.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.reordered, actorId: null),
        ),
        "An object's stacking order changed.",
      );
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.restored, actorId: null, count: 2),
        ),
        '2 objects were restored.',
      );
    });

    test('a disclosed moderator (MANAGE_CANVAS) is named plainly', () {
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.removed, actorId: 'mod', count: 3),
          nameFor: (_) => 'Mod',
        ),
        'Mod removed 3 objects.',
      );
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.reordered, actorId: 'mod'),
          nameFor: (_) => 'Mod',
        ),
        "Mod changed an object's stacking order.",
      );
    });

    test('a resync names no actor at all, disclosed or otherwise', () {
      expect(
        describeCanvasActivityEntry(
          _entry(kind: CanvasActivityKind.resynced, actorId: null),
          nameFor: (_) => 'Anyone',
        ),
        'The canvas reloaded from the server.',
      );
    });
  });

  group('summarizeCanvasActivity', () {
    test('an empty batch summarizes to nothing', () {
      expect(summarizeCanvasActivity(const []), '');
    });

    test('a batch of one delegates to the single-entry sentence', () {
      expect(
        summarizeCanvasActivity([
          _entry(actorId: 'alice', objectKind: 'stroke'),
        ], nameFor: (_) => 'Alice'),
        'Alice placed a stroke.',
      );
    });

    test('a batch of several aggregates counts per kind rather than naming '
        'each change', () {
      final batch = [
        _entry(id: 'a', kind: CanvasActivityKind.placed),
        _entry(id: 'b', kind: CanvasActivityKind.placed),
        _entry(id: 'c', kind: CanvasActivityKind.removed, count: 2),
      ];

      final summary = summarizeCanvasActivity(batch);

      expect(summary, contains('2 placed'));
      expect(summary, contains('2 removed'));
      expect(summary, startsWith('Canvas activity:'));
    });
  });
}
