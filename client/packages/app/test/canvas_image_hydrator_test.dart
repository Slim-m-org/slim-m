// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasImageHydrator]: fetching and decoding the bitmap for a placed
/// image object arriving from anywhere other than this client's own paste.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_image_hydrator.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// A 1x1 transparent PNG: real bytes, so a decode succeeds rather than
/// throwing.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// Waits for [ready] rather than for a fixed number of event-loop turns.
///
/// `pumpEventQueue` drains microtasks; decoding a PNG is engine work that is
/// not one, so a fixed drain finishes it on an idle machine and does not on a
/// loaded CI runner. This is the same shape CLAUDE.md already records for
/// `toImage`, and it is what made this file flake once rather than fail.
Future<void> _settleUntil(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.SlimmApi _fakeApi(
  Future<http.Response> Function(String attachmentId) onFetch,
) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: api.SessionStore(tokens: _tokens),
  httpClient: MockClient((request) async {
    final match = RegExp(r'^/attachments/(.+)$').firstMatch(request.url.path);
    if (match == null) {
      return http.Response(jsonEncode(<Object>[]), 200);
    }
    return onFetch(match.group(1)!);
  }),
);

api.CanvasObject _imageObject(String id, {String attachment = 'sha-1'}) =>
    api.CanvasObject(
      id: id,
      kind: 'image',
      zIndex: 1,
      x: 0,
      y: 0,
      w: 20,
      h: 20,
      props: {'attachment': attachment, 'content_type': 'image/png'},
      authorId: 'someone-else',
      seq: 1,
      createdAt: 0,
    );

CanvasDocument _documentHolding(String id) {
  final document = CanvasDocument()..setViewport(const Size(200, 200));
  document
    ..applyPlaced(
      CanvasStrokeInput(
        id: id,
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 20,
        h: 20,
        points: const [],
        width: 0,
        colorKey: '',
        kind: CanvasObjectKind.image,
        attachmentId: 'sha-1',
      ),
    )
    ..refresh();
  return document;
}

void main() {
  test('hydrate fetches, decodes and attaches the bitmap', () async {
    var fetches = 0;
    final document = _documentHolding('a');
    addTearDown(document.dispose);
    final hydrator = CanvasImageHydrator(
      client: _fakeApi((id) async {
        fetches++;
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
      document: document,
    );
    addTearDown(hydrator.dispose);

    hydrator.hydrate(_imageObject('a'));
    await _settleUntil(
      () =>
          fetches == 1 &&
          document.paintOrder.isNotEmpty &&
          document.strokeIfAlive(document.paintOrder.single)?.image != null,
    );

    expect(fetches, 1);
    expect(document.objectBounds('a'), isNotNull);
    final slot = document.strokeIfAlive(document.paintOrder.single)!;
    expect(slot.image, isNotNull);
    expect(slot.imageLoadFailed, isFalse);
  });

  test(
    'hydrate is a no-op for a stroke, or an image with no attachment id',
    () async {
      var fetches = 0;
      final document = _documentHolding('a');
      addTearDown(document.dispose);
      final hydrator = CanvasImageHydrator(
        client: _fakeApi((id) async {
          fetches++;
          return http.Response.bytes(_png, 200);
        }),
        document: document,
      );
      addTearDown(hydrator.dispose);

      hydrator.hydrate(
        api.CanvasObject(
          id: 'a',
          kind: 'stroke',
          zIndex: 1,
          x: 0,
          y: 0,
          w: 20,
          h: 20,
          props: const {'points': <dynamic>[]},
          authorId: 'someone-else',
          seq: 1,
          createdAt: 0,
        ),
      );
      hydrator.hydrate(
        api.CanvasObject(
          id: 'a',
          kind: 'image',
          zIndex: 1,
          x: 0,
          y: 0,
          w: 20,
          h: 20,
          props: const {},
          authorId: 'someone-else',
          seq: 1,
          createdAt: 0,
        ),
      );
      await pumpEventQueue();

      expect(fetches, 0);
    },
  );

  test('a second hydrate call for an already-hydrated id fetches nothing '
      'more', () async {
    var fetches = 0;
    final document = _documentHolding('a');
    addTearDown(document.dispose);
    final hydrator = CanvasImageHydrator(
      client: _fakeApi((id) async {
        fetches++;
        return http.Response.bytes(_png, 200);
      }),
      document: document,
    );
    addTearDown(hydrator.dispose);

    hydrator.hydrate(_imageObject('a'));
    await pumpEventQueue();
    hydrator.hydrate(_imageObject('a'));
    hydrator.hydrate(_imageObject('a'));
    await pumpEventQueue();

    expect(fetches, 1);
  });

  test(
    'a fetch that fails marks the object load-failed rather than retrying',
    () async {
      var fetches = 0;
      final document = _documentHolding('a');
      addTearDown(document.dispose);
      final hydrator = CanvasImageHydrator(
        client: _fakeApi((id) async {
          fetches++;
          return http.Response(jsonEncode({'error': 'no'}), 403);
        }),
        document: document,
      );
      addTearDown(hydrator.dispose);

      hydrator.hydrate(_imageObject('a'));
      await pumpEventQueue();

      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(slot.image, isNull);
      expect(slot.imageLoadFailed, isTrue);

      hydrator.hydrate(_imageObject('a'));
      await pumpEventQueue();

      expect(
        fetches,
        1,
        reason:
            'a 403 is a stable answer, not a transient error worth '
            'retrying automatically',
      );
    },
  );

  test('a bound past maxDecodedBytes evicts the oldest off-screen bitmap, and '
      'a later hydrate call re-fetches it', () async {
    final fetchedIds = <String>[];
    final document = CanvasDocument()..setViewport(const Size(200, 200));
    for (final (id, x) in [('a', 0.0), ('b', 5000.0)]) {
      document.applyPlaced(
        CanvasStrokeInput(
          id: id,
          seq: 1,
          zIndex: 1,
          x: x,
          y: 0,
          w: 20,
          h: 20,
          points: const [],
          width: 0,
          colorKey: '',
          kind: CanvasObjectKind.image,
          attachmentId: 'sha-$id',
        ),
      );
    }
    document.refresh();
    addTearDown(document.dispose);

    final hydrator = CanvasImageHydrator(
      client: _fakeApi((id) async {
        fetchedIds.add(id);
        return http.Response.bytes(_png, 200);
      }),
      document: document,
      // The 1x1 PNG decodes to 4 bytes (1*1*4); one bitmap fits, two do not.
      maxDecodedBytes: 4,
    );
    addTearDown(hydrator.dispose);

    hydrator.hydrate(_imageObject('a', attachment: 'sha-a'));
    // A decode is engine work `pumpEventQueue` cannot wait out; see `_settleUntil`.
    await _settleUntil(() => document.hasImageBitmap('a'));

    // The view moves to b, so a is now the one off screen.
    document
      ..setCamera(const Camera(x: 4900, y: 0))
      ..refresh();
    hydrator.hydrate(_imageObject('b', attachment: 'sha-b'));
    await _settleUntil(
      () => document.hasImageBitmap('b') && !document.hasImageBitmap('a'),
    );

    expect(
      document.hasImageBitmap('a'),
      isFalse,
      reason: 'off screen and oldest, so evicted to make room',
    );
    expect(document.hasImageBitmap('b'), isTrue);

    hydrator.hydrate(_imageObject('a', attachment: 'sha-a'));
    await _settleUntil(
      () => fetchedIds.where((id) => id == 'sha-a').length == 2,
    );

    expect(
      fetchedIds.where((id) => id == 'sha-a').length,
      2,
      reason: 'an evicted image still awaits a bitmap, so it fetches again',
    );
  });

  test(
    'dispose stops a late-arriving fetch from touching the document',
    () async {
      final document = _documentHolding('a');
      addTearDown(document.dispose);
      final pending = Completer<http.Response>();
      final hydrator = CanvasImageHydrator(
        client: _fakeApi((id) => pending.future),
        document: document,
      );

      hydrator.hydrate(_imageObject('a'));
      hydrator.dispose();
      pending.complete(http.Response.bytes(_png, 200));
      await pumpEventQueue();

      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      expect(
        slot.image,
        isNull,
        reason:
            'a disposed hydrator must not mutate a pane that may itself '
            'be gone by the time its fetch completes',
      );
    },
  );
}
