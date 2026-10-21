// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Both decode paths bound the bitmap the same way; the web one checks the
/// size after the browser decode, so it is driven here through its entry point.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/bounded_image_decode.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

typedef _Decode =
    Future<ui.Image> Function(
      Uint8List, {
      required int maxSide,
      int? maxSourcePixels,
    });

Future<ui.Image> _viaWeb(
  Uint8List bytes, {
  required int maxSide,
  int? maxSourcePixels,
}) => decodeBoundedViaPostDecodeCheck(bytes, maxSide, maxSourcePixels);

void main() {
  final paths = <String, _Decode>{'native': decodeBoundedImage, 'web': _viaWeb};
  for (final entry in paths.entries) {
    final decode = entry.value;
    group('${entry.key} path', () {
      testWidgets('keeps a normal image at its size', (tester) async {
        await tester.runAsync(() async {
          final image = await decode(await _png(40, 20), maxSide: 100);
          expect([image.width, image.height], [40, 20]);
          image.dispose();
        });
      });

      testWidgets('shrinks a wide image to the bound, keeping aspect', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final image = await decode(await _png(400, 200), maxSide: 100);
          expect([image.width, image.height], [100, 50]);
          image.dispose();
        });
      });

      testWidgets('shrinks a tall image to the bound, keeping aspect', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final image = await decode(await _png(200, 400), maxSide: 100);
          expect([image.width, image.height], [50, 100]);
          image.dispose();
        });
      });

      testWidgets('refuses an image past the pixel budget', (tester) async {
        await tester.runAsync(() async {
          final bytes = await _png(400, 200);
          await expectLater(
            decode(bytes, maxSide: 100, maxSourcePixels: 1000),
            throwsA(
              isA<ImageTooLargeException>()
                  .having((e) => e.width, 'width', 400)
                  .having((e) => e.height, 'height', 200),
            ),
          );
        });
      });

      testWidgets('accepts an image exactly at the pixel budget', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final image = await decode(
            await _png(40, 20),
            maxSide: 100,
            maxSourcePixels: 800,
          );
          expect(image.width, 40);
          image.dispose();
        });
      });

      testWidgets('an undecodable blob fails as a read error, not too-large', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final junk = Uint8List.fromList(List<int>.filled(64, 7));
          await expectLater(
            decode(junk, maxSide: 100, maxSourcePixels: 1000),
            throwsA(isNot(isA<ImageTooLargeException>())),
          );
        });
      });
    });
  }
}
