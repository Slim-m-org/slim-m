// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasImageHydrator] under load and failure: a bounded number of fetches
/// at once, a transient error retried, and only a real refusal marked failed.
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

CanvasDocument _documentHolding(List<String> ids) {
  final document = CanvasDocument()..setViewport(const Size(200, 200));
  for (final (i, id) in ids.indexed) {
    document.applyPlaced(
      CanvasStrokeInput(
        id: id,
        seq: i + 1,
        zIndex: i + 1,
        x: 0,
        y: 0,
        w: 20,
        h: 20,
        points: const [],
        width: 0,
        colorKey: '',
        kind: CanvasObjectKind.image,
        attachmentId: 'sha-$i',
      ),
    );
  }
  return document..refresh();
}

Future<void> _noWait(Duration _) async {}

http.Response _pngResponse() =>
    http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});

void main() {
  Future<CanvasDocument> run(
    Future<http.Response> Function(int attempt) answer,
  ) async {
    var attempts = 0;
    final document = _documentHolding(['a']);
    addTearDown(document.dispose);
    final hydrator = CanvasImageHydrator(
      client: _fakeApi((id) {
        attempts++;
        return answer(attempts);
      }),
      document: document,
      wait: _noWait,
    );
    addTearDown(hydrator.dispose);
    hydrator.hydrate(_imageObject('a'));
    return document;
  }

  test('a 429 on the first fetch is retried and the image hydrates', () async {
    final r = await run(
      (n) async => n == 1
          ? http.Response(jsonEncode({'error': 'slow down'}), 429)
          : _pngResponse(),
    );
    final slot = r.strokeIfAlive(r.paintOrder.single)!;
    await _settleUntil(() => slot.image != null || slot.imageLoadFailed);

    expect(slot.imageLoadFailed, isFalse, reason: 'a 429 is transient');
    expect(slot.image, isNotNull);
  });

  test('a transport error on the first fetch is retried', () async {
    final r = await run((n) async {
      if (n == 1) throw http.ClientException('connection reset');
      return _pngResponse();
    });
    final slot = r.strokeIfAlive(r.paintOrder.single)!;
    await _settleUntil(() => slot.image != null || slot.imageLoadFailed);

    expect(slot.imageLoadFailed, isFalse);
    expect(slot.image, isNotNull);
  });

  test('a 404 is a real answer: failed at once, never retried', () async {
    var attempts = 0;
    final r = await run((n) async {
      attempts = n;
      return http.Response(jsonEncode({'error': 'gone'}), 404);
    });
    final slot = r.strokeIfAlive(r.paintOrder.single)!;
    await _settleUntil(() => slot.imageLoadFailed);

    expect(slot.imageLoadFailed, isTrue);
    expect(attempts, 1);
  });

  test(
    'an error that outlasts the retries is not marked permanently failed',
    () async {
      var attempts = 0;
      final r = await run((n) async {
        attempts = n;
        return http.Response('', 503);
      });
      await _settleUntil(() => attempts >= imageFetchAttempts);
      await pumpEventQueue();
      final slot = r.strokeIfAlive(r.paintOrder.single)!;

      expect(attempts, imageFetchAttempts);
      expect(slot.imageLoadFailed, isFalse);
      expect(r.imageAwaitsBitmap('a'), isTrue);
    },
  );

  test('200 images never have more than the cap in flight', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    var started = 0;
    final ids = [for (var i = 0; i < 200; i++) 'o$i'];
    final document = _documentHolding(ids);
    addTearDown(document.dispose);
    final gate = Completer<void>();
    final hydrator = CanvasImageHydrator(
      client: _fakeApi((id) async {
        started++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await gate.future;
        inFlight--;
        return _pngResponse();
      }),
      document: document,
      wait: _noWait,
    );
    addTearDown(hydrator.dispose);

    for (final (i, id) in ids.indexed) {
      hydrator.hydrate(_imageObject(id, attachment: 'sha-$i'));
    }
    await _settleUntil(() => started >= maxConcurrentImageFetches);
    await pumpEventQueue();

    expect(started, maxConcurrentImageFetches);
    expect(maxInFlight, maxConcurrentImageFetches);
    gate.complete();
    await _settleUntil(() => started >= 200 && inFlight == 0);
    expect(started, 200);
    expect(maxInFlight, maxConcurrentImageFetches);
  });
}
