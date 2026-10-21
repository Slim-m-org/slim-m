// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hydrator fetches a placed image at the size it is drawn, not as the
/// original, so a board of photos seen at fit stays inside the decode budget.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_image_hydrator.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/synthetic_png.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

void main() {
  test(
    'a small on-screen image is fetched as a preview, not the original',
    () async {
      final urls = <Uri>[];
      final png = solidPng(1500, 1500);
      final document = CanvasDocument()..setViewport(const Size(400, 400));
      final hydrator = CanvasImageHydrator(
        client: testApi(
          (request) async {
            urls.add(request.url);
            return http.Response.bytes(
              png,
              200,
              headers: {'content-type': 'image/png'},
            );
          },
          session: api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 0,
            ),
          ),
        ),
        document: document,
      );
      addTearDown(() {
        hydrator.dispose();
        document.dispose();
      });
      document
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'a',
            seq: 1,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 20,
            h: 20,
            points: [],
            width: 0,
            colorKey: '',
            kind: CanvasObjectKind.image,
            attachmentId: 'att-a',
          ),
        )
        ..refresh();
      hydrator.hydrate(
        const api.CanvasObject(
          id: 'a',
          kind: 'image',
          zIndex: 1,
          x: 0,
          y: 0,
          w: 20,
          h: 20,
          props: {'attachment': 'att-a', 'content_type': 'image/png'},
          authorId: 'someone-else',
          seq: 1,
          createdAt: 0,
        ),
      );
      for (var i = 0; i < 200 && urls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(urls, hasLength(1));
      expect(urls.single.queryParameters, contains('w'));
    },
  );

  test('zooming in swaps a coarse bitmap for a finer tier', () async {
    final urls = <Uri>[];
    final png = solidPng(1500, 1500);
    final document = CanvasDocument()..setViewport(const Size(400, 400));
    final hydrator = CanvasImageHydrator(
      client: testApi(
        (request) async {
          urls.add(request.url);
          return http.Response.bytes(
            png,
            200,
            headers: {'content-type': 'image/png'},
          );
        },
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      document: document,
    )..devicePixelRatio = 1;
    addTearDown(() {
      hydrator.dispose();
      document.dispose();
    });
    document
      ..applyPlaced(
        const CanvasStrokeInput(
          id: 'a',
          seq: 1,
          zIndex: 1,
          x: 0,
          y: 0,
          w: 200,
          h: 200,
          points: [],
          width: 0,
          colorKey: '',
          kind: CanvasObjectKind.image,
          attachmentId: 'att-a',
        ),
      )
      ..refresh();
    hydrator.hydrateVisible();
    for (var i = 0; i < 400 && !document.hasImageBitmap('a'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(hydrator.tierOf('a'), 320);

    document
      ..setCamera(const Camera(zoom: 2))
      ..refresh();
    hydrator.hydrateVisible();
    for (var i = 0; i < 400 && hydrator.tierOf('a') != 640; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(hydrator.tierOf('a'), 640);
    expect(urls.map((u) => u.queryParameters['w']), ['320', '640']);
    expect(hydrator.decodedBytes, lessThan(640 * 640 * 4 + 1));
  });
}
