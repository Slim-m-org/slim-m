// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Editing a placed note's text: the ops controller shows it at once, posts
/// one `edit` op, reverses and repeats it through undo and redo, and a
/// catch-up replays someone else's edit.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_note_sizing.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_sync.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import '../../support/canvas_ops_rig.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

CanvasStrokeInput _note(String id, String text) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 120,
  h: 80,
  points: const [],
  width: 0,
  colorKey: 'note',
  authorId: 'me',
  kind: CanvasObjectKind.note,
  text: text,
);

api.SlimmApi _client(Future<http.Response> Function(http.Request) handler) =>
    testApi(
      handler,
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    );

class _Harness {
  _Harness({Set<String> locked = const {}}) {
    final client = _client((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      if (failOps) return _json({'error': 'no'}, 403);
      _seq++;
      return _json({
        'op': {
          'id': 'server-op-$_seq',
          'seq': _seq,
          'kind': body['kind'],
          'affected': 1,
          'created_at': 0,
        },
        'fresh': true,
      });
    });
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: plainCommitQueue(client),
      onError: errors.add,
      isLocked: locked.contains,
    );
    document
      ..applyPlaced(_note('n', 'first'))
      ..refresh();
  }

  final CanvasDocument document = CanvasDocument()
    ..setViewport(const Size(800, 600));
  late final CanvasOpsController ops;
  final List<Map<String, dynamic>> requests = [];
  final List<String> errors = [];
  bool failOps = false;
  var _seq = 0;
}

void main() {
  test('editing a note to much longer text regrows its box', () {
    fakeAsync((async) {
      final h = _Harness();
      final longText = List.generate(8, (i) => 'paragraph $i\n').join();
      final needed = noteBoxFor(longText).height;
      expect(needed, greaterThan(80), reason: 'the fixture note is 80 tall');

      unawaited(h.ops.editNote('n', longText));
      async.flushMicrotasks();

      final grows = h.requests.where(
        (r) => r['kind'] == 'move' && ((r['h'] as num?) ?? 0) >= needed,
      );
      expect(
        grows,
        isNotEmpty,
        reason:
            'only ${h.requests.map((r) => r['kind'])} were sent, so the '
            'note keeps its box and clips the longer text',
      );
    });
  });

  test('editing shows the text at once and posts one edit op', () {
    fakeAsync((async) {
      final h = _Harness();

      unawaited(h.ops.editNote('n', 'second'));
      expect(h.document.noteTextOf('n'), 'second');
      async.flushMicrotasks();

      expect(h.requests, hasLength(1));
      expect(h.requests.single['kind'], 'edit');
      expect(h.requests.single['object_id'], 'n');
      expect(h.requests.single['props'], {'text': 'second'});
      expect(h.ops.canUndo, isTrue);
    });
  });

  test('undo puts the old text back and redo writes the new one again', () {
    fakeAsync((async) {
      final h = _Harness();
      unawaited(h.ops.editNote('n', 'second'));
      async.flushMicrotasks();

      unawaited(h.ops.undo());
      async.flushMicrotasks();
      expect(h.document.noteTextOf('n'), 'first');
      expect(h.requests.last['kind'], 'edit');
      expect(h.requests.last['props'], {'text': 'first'});
      expect(h.ops.canRedo, isTrue);

      unawaited(h.ops.redo());
      async.flushMicrotasks();
      expect(h.document.noteTextOf('n'), 'second');
      expect(h.requests.last['props'], {'text': 'second'});
      expect(h.requests, hasLength(3));
    });
  });

  test('a refused edit puts the old text back and says so', () {
    fakeAsync((async) {
      final h = _Harness()..failOps = true;

      unawaited(h.ops.editNote('n', 'second'));
      async.flushMicrotasks();

      expect(h.document.noteTextOf('n'), 'first');
      expect(h.errors, ['That note could not be edited.']);
      expect(h.ops.canUndo, isFalse);
    });
  });

  test('a locked note, an unchanged text and a missing note send nothing', () {
    fakeAsync((async) {
      final h = _Harness(locked: {'n'});

      unawaited(h.ops.editNote('n', 'second'));
      unawaited(h.ops.editNote('n', 'first'));
      unawaited(h.ops.editNote('gone', 'x'));
      async.flushMicrotasks();

      expect(h.requests, isEmpty);
      expect(h.document.noteTextOf('n'), 'first');
    });
  });

  test('a catch-up replays a remote edit onto the note', () {
    fakeAsync((async) {
      final document = CanvasDocument()
        ..applyPlaced(_note('n', 'first'))
        ..refresh();
      final sync = CanvasSync(
        channelId: 'c1',
        client: _client((request) async {
          final afterSeq = int.parse(request.url.queryParameters['after_seq']!);
          return _json({
            'ops': afterSeq == 0
                ? [
                    {
                      'seq': 1,
                      'id': 'op-1',
                      'actor_id': 'you',
                      'created_at': 0,
                      'kind': 'edit',
                      'object_id': 'n',
                      'props': {'text': 'edited elsewhere'},
                    },
                  ]
                : <Object>[],
            'latest_seq': 1,
            'has_more': false,
            'reset': false,
          });
        }),
        document: document,
        coldFetch: () async {},
        forgetFetchedRegion: () {},
      )..seedFromViewport(0);

      unawaited(sync.catchUp());
      async.flushMicrotasks();

      expect(document.noteTextOf('n'), 'edited elsewhere');
    });
  });
}
