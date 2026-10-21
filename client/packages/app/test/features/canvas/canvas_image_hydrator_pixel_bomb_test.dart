// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasImageHydrator]: a small encoded image declaring a huge pixel size
/// must be refused, not decoded, on every viewer.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_image_hydrator.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import '../../support/pixel_bomb_png.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _side = 8000;

void main() {
  test('a pixel-bomb image is marked load-failed, not decoded', () async {
    final bomb = pixelBombPng(_side);
    expect(bomb.length, lessThan(1024 * 1024));
    final document = CanvasDocument()..setViewport(const Size(200, 200));
    addTearDown(document.dispose);
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
          attachmentId: 'sha-1',
        ),
      )
      ..refresh();
    final hydrator = CanvasImageHydrator(
      client: testApi(
        (request) async => http.Response.bytes(
          bomb,
          200,
          headers: {'content-type': 'image/png'},
        ),
        session: api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      document: document,
    );
    addTearDown(hydrator.dispose);

    hydrator.hydrate(
      const api.CanvasObject(
        id: 'a',
        kind: 'image',
        zIndex: 1,
        x: 0,
        y: 0,
        w: 20,
        h: 20,
        props: {'attachment': 'sha-1', 'content_type': 'image/png'},
        authorId: 'someone-else',
        seq: 1,
        createdAt: 0,
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final slot = document.strokeIfAlive(document.paintOrder.single)!;
      if (slot.image != null || slot.imageLoadFailed) break;
    }
    final slot = document.strokeIfAlive(document.paintOrder.single)!;
    expect(slot.image, isNull, reason: '${_side}x$_side was fully decoded');
    expect(slot.imageLoadFailed, isTrue);
  });
}
