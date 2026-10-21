// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasImageHydrator]: a small encoded image declaring a huge pixel size
/// must be refused, not decoded, on every viewer.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_image_hydrator.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _side = 8000;

int _crc(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> body) {
  final head = ascii.encode(type) + body;
  final out = ByteData(4)..setUint32(0, body.length);
  final crc = ByteData(4)..setUint32(0, _crc(head));
  return [...out.buffer.asUint8List(), ...head, ...crc.buffer.asUint8List()];
}

/// A valid all-black 8-bit grayscale PNG of 64 MP that compresses to a
/// small payload.
Uint8List _pixelBomb() {
  final ihdr = ByteData(13)
    ..setUint32(0, _side)
    ..setUint32(4, _side)
    ..setUint8(8, 8)
    ..setUint8(9, 0);
  final row = Uint8List(_side + 1);
  late final List<int> idat;
  final sink = ZLibEncoder().startChunkedConversion(
    ByteConversionSink.withCallback((bytes) => idat = bytes),
  );
  for (var y = 0; y < _side; y++) {
    sink.add(row);
  }
  sink.close();
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ..._chunk('IHDR', ihdr.buffer.asUint8List()),
    ..._chunk('IDAT', idat),
    ..._chunk('IEND', const []),
  ]);
}

void main() {
  test('a pixel-bomb image is marked load-failed, not decoded', () async {
    final bomb = _pixelBomb();
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
      api.CanvasObject(
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
