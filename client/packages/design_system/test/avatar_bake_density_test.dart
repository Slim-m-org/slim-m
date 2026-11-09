// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A picture avatar is baked at three pixels per logical pixel, the density
/// that fixed the Linux 1x edge; a denser display bakes at its own density
/// instead of three times it, which was half a megabyte per 40dp avatar at 3x.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

class _Picture extends ImageProvider<_Picture> {
  const _Picture(this.image);

  final ui.Image image;

  @override
  Future<_Picture> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Picture key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: image.clone())),
      );
}

Future<int> _bakedEdge(
  WidgetTester tester, {
  required double size,
  required double devicePixelRatio,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);
  final source = (await tester.runAsync(
    () => createTestImage(width: 64, height: 64),
  ))!;
  addTearDown(source.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Align(
        alignment: Alignment.topLeft,
        child: AppShapedImage(
          image: _Picture(source),
          size: size,
          radius: size / 2,
          errorBuilder: (_) => const SizedBox.shrink(),
        ),
      ),
    ),
  );
  final box = tester.renderObject<RenderCustomPaint>(
    find.descendant(
      of: find.byType(AppShapedImage),
      matching: find.byType(CustomPaint),
    ),
  );
  final context = _RecordedImageRect();
  box.painter!.paint(context, box.size);
  return context.source!.width.round();
}

class _RecordedImageRect implements Canvas {
  Rect? source;

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    source = src;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  for (final (ratio, expected) in [
    (1.0, 120),
    (2.0, 120),
    (3.0, 120),
    (4.0, 160),
  ]) {
    testWidgets('a 40dp avatar at ${ratio}x bakes at $expected px', (
      tester,
    ) async {
      expect(
        await _bakedEdge(tester, size: 40, devicePixelRatio: ratio),
        expected,
      );
    });
  }

  testWidgets('a huge avatar still stops at the bake cap', (tester) async {
    expect(
      await _bakedEdge(tester, size: 600, devicePixelRatio: 3),
      1024,
    );
  });
}
