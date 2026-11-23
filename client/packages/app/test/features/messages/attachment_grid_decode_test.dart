// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What each gallery tile really decodes, against the tile's size in physical
/// pixels, per preview-quality level and device pixel ratio.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_quality.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_gallery.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_design_system/design_system.dart';

/// A photo-shaped PNG whose longer side is [longest] and whose ratio is [ratio] (width over height).
Future<Uint8List> _photo(int longest, double ratio) async {
  final w = ratio >= 1 ? longest : (longest * ratio).round();
  final h = ratio >= 1 ? (longest / ratio).round() : longest;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..shader = ui.Gradient.linear(
      Offset.zero,
      Offset(w.toDouble(), h.toDouble()),
      [Colors.orange, Colors.indigo],
    );
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), paint);
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

api.Attachment _image(int i) => api.Attachment(
  id: 'img-$i',
  filename: 'photo-$i.jpg',
  contentType: 'image/jpeg',
  size: 4000000,
);

typedef _Decoded = ({Size tile, int width, int height});

Future<List<_Decoded>> _decodedTiles(
  WidgetTester tester, {
  required int count,
  required double ratio,
  required double dpr,
  required double width,
  required AttachmentPreviewQuality quality,
}) async {
  tester.view.physicalSize = Size(width * dpr, 1600 * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  final previews = <int, Uint8List>{};
  await tester.runAsync(() async {
    for (final bucket in attachmentPreviewBuckets) {
      previews[bucket] = await _photo(bucket, ratio);
    }
  });
  final attachments = [for (var i = 0; i < count; i++) _image(i)];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        for (final a in attachments)
          attachmentBytesProvider(
            a.id,
          ).overrideWith((ref) async => previews[1280]!),
        attachmentPreviewBytesProvider.overrideWith(
          (ref, key) async => previews[key.bucket]!,
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MessageAttachments(attachments: attachments),
            ),
          ),
        ),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byWidgetPredicate((w) => w is MessageAttachments)),
  );
  container.read(attachmentPreviewQualityControllerProvider.notifier).state =
      quality;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final out = <_Decoded>[];
  for (final view in tester.widgetList<AttachmentView>(
    find.byWidgetPredicate((w) => w is AttachmentView),
  )) {
    final tile = tester.getSize(find.byWidget(view));
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byWidget(view),
        matching: find.byWidgetPredicate((w) => w is Image),
      ),
    );
    final decoded = await tester.runAsync(() => _resolve(image.image));
    out.add((tile: tile, width: decoded!.width, height: decoded.height));
  }
  return out;
}

Future<ui.Image> _resolve(ImageProvider provider) {
  final done = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    done.complete(info.image);
    stream.removeListener(listener);
  });
  stream.addListener(listener);
  return done.future;
}

int _shorter(_Decoded d) => math.min(d.width, d.height);

void main() {
  const sharp = AttachmentPreviewQuality.sharp;
  for (final dpr in [1.0, 2.0]) {
    for (final width in [390.0, 1280.0]) {
      for (final count in [2, 3, 4, 6]) {
        for (final ratio in [4 / 3, 3 / 2, 3 / 4, 1.0]) {
          testWidgets(
            'sharp: every tile decodes to its physical size '
            '(dpr $dpr, $width wide, $count images, ratio ${ratio.toStringAsFixed(2)})',
            (tester) async {
              final tiles = await _decodedTiles(
                tester,
                count: count,
                ratio: ratio,
                dpr: dpr,
                width: width,
                quality: sharp,
              );
              expect(tiles, hasLength(math.min(count, kGalleryMaxTiles)));
              for (final t in tiles) {
                final physical = t.tile.width * dpr;
                expect(_shorter(t), greaterThanOrEqualTo(physical.floor()));
                // Bounded: never the whole preview decoded into a tile.
                expect(_shorter(t), lessThanOrEqualTo(physical.ceil() + 1));
              }
            },
          );
        }
      }
    }
  }

  testWidgets('lower settings still decode fewer pixels than sharp', (
    tester,
  ) async {
    final shorter = <AttachmentPreviewQuality, int>{};
    for (final q in AttachmentPreviewQuality.values) {
      final tiles = await _decodedTiles(
        tester,
        count: 4,
        ratio: 3 / 2,
        dpr: 2,
        width: 1280,
        quality: q,
      );
      shorter[q] = _shorter(tiles.first);
      final physical = tiles.first.tile.width * 2;
      if (q != sharp) {
        expect(shorter[q]!, lessThan(physical * q.decodeScale + 2));
      }
    }
    expect(
      shorter[AttachmentPreviewQuality.dataSaver]!,
      lessThan(shorter[AttachmentPreviewQuality.balanced]!),
    );
    expect(
      shorter[AttachmentPreviewQuality.balanced]!,
      lessThan(shorter[sharp]!),
    );
  });
}
