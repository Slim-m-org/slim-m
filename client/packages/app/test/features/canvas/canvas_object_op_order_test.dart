// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Changes to one object go to the server in the order they were made, and a
/// change that may have landed without a reply is settled against the server.
library;

import 'dart:async';
import 'dart:convert';

import 'dart:ui' show Size;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_ops_controller.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_ops_rig.dart';

class _Rig {
  _Rig(
    Future<http.Response> Function(Map<String, dynamic> body, int n) answer, {
    double? fontSize,
  }) {
    final client = testApi(
      (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        return answer(body, requests.length);
      },
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    );
    document
      ..applyPlaced(
        CanvasStrokeInput(
          id: 'note',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 100,
          h: 100,
          points: const [],
          width: 0,
          colorKey: 'note',
          authorId: 'me',
          kind: CanvasObjectKind.note,
          text: 'start',
          fontSize: fontSize,
        ),
      )
      ..refresh();
    ops = CanvasOpsController(
      channelId: 'c1',
      client: client,
      document: document,
      commits: plainCommitQueue(client),
      onError: errors.add,
      onUnknownOutcome: () async => unknownOutcomes++,
    );
  }

  final document = CanvasDocument()..setViewport(const Size(800, 600));
  late final CanvasOpsController ops;
  final requests = <Map<String, dynamic>>[];
  final errors = <String>[];
  var unknownOutcomes = 0;
}

void main() {
  test('a second edit waits for the first to settle', () {
    fakeAsync((async) {
      final first = Completer<http.Response>();
      final rig = _Rig(
        (body, n) => n == 1
            ? first.future
            : Future.value(acceptedOp(n: n, kind: 'edit', affected: 1)),
      );
      unawaited(rig.ops.editNote('note', 'one'));
      unawaited(rig.ops.editNote('note', 'two'));
      async.flushMicrotasks();
      expect(
        rig.requests,
        hasLength(1),
        reason: 'the second must queue behind',
      );

      first.complete(acceptedOp(n: 1, kind: 'edit', affected: 1));
      async.flushMicrotasks();
      expect(rig.requests.map((r) => r['props']['text']), ['one', 'two']);
    });
  });

  test('a change that failed with no reply is settled against the feed', () {
    fakeAsync((async) {
      final rig = _Rig((body, n) => Future.error(http.ClientException('down')));
      unawaited(rig.ops.editNote('note', 'one'));
      async.elapse(const Duration(minutes: 2));
      expect(rig.unknownOutcomes, 1);
      expect(rig.errors, isNotEmpty);
      expect(rig.document.noteTextOf('note'), 'start');
    });
  });

  test(
    'a refusal says the server did not apply it, so no feed read follows',
    () {
      fakeAsync((async) {
        final rig = _Rig(
          (body, n) => Future.value(
            http.Response(
              jsonEncode({'error': 'no'}),
              403,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        unawaited(rig.ops.editNote('note', 'one'));
        async.flushMicrotasks();
        expect(rig.unknownOutcomes, 0);
        expect(rig.errors, isNotEmpty);
      });
    },
  );

  test('an edit sends the note\'s stored text size along with its text', () {
    fakeAsync((async) {
      final rig = _Rig(
        (body, n) => Future.value(acceptedOp(n: n, kind: 'edit', affected: 1)),
        fontSize: 18,
      );
      unawaited(rig.ops.editNote('note', 'changed'));
      async.flushMicrotasks();
      expect(rig.requests.single['props'], {
        'text': 'changed',
        'font_size': 18,
      });
    });
  });
}
