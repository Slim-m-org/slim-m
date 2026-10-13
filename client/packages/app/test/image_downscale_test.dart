// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone photo over the server's cap is shrunk before upload, not refused.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/image_downscale.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<({int width, int height})> _size(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final size = (width: frame.image.width, height: frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return size;
}

void main() {
  testWidgets('a picture past the edge is shrunk, keeping its aspect', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final big = await _png(3000, 1000);
      final out = await downscaledToFit(big, maxEdge: 1280, maxBytes: 1 << 22);
      final size = await _size(out);
      expect(size.width, 1280);
      expect(size.height, closeTo(427, 1));
    });
  });

  testWidgets('a portrait picture is limited on its height', (tester) async {
    await tester.runAsync(() async {
      final tall = await _png(1000, 3000);
      final out = await downscaledToFit(tall, maxEdge: 1280, maxBytes: 1 << 22);
      final size = await _size(out);
      expect(size.height, 1280);
      expect(size.width, closeTo(427, 1));
    });
  });

  testWidgets('a picture already inside both limits is returned untouched', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final small = await _png(300, 100);
      final out = await downscaledToFit(
        small,
        maxEdge: 1280,
        maxBytes: 1 << 22,
      );
      expect(identical(out, small), isTrue);
    });
  });

  testWidgets('a picture over the byte cap shrinks until it fits', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final big = await _png(1200, 1200);
      final cap = big.length ~/ 2;
      final out = await downscaledToFit(big, maxEdge: 1280, maxBytes: cap);
      final size = await _size(out);
      expect(out.length, lessThanOrEqualTo(cap));
      expect(size.width, lessThan(1200));
    });
  });

  testWidgets('bytes nothing can decode pass through for the server to judge', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final junk = Uint8List.fromList([1, 2, 3]);
      final out = await downscaledToFit(junk, maxEdge: 10, maxBytes: 1);
      expect(identical(out, junk), isTrue);
    });
  });
}
