// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Baking an avatar's shape records a picture only to turn it into an image,
/// so the picture is disposed there rather than left for a collection.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

class _Source extends ImageProvider<_Source> {
  const _Source(this.image);

  final ui.Image image;

  @override
  Future<_Source> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Source key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: image.clone())),
      );
}

void main() {
  testWidgets(
      'no picture recorded for an avatar outlives the frame that '
      'drew it', (tester) async {
    final recorded = <ui.Picture>[];
    void onEvent(ObjectEvent event) {
      final object = event.object;
      if (event is ObjectCreated && object is ui.Picture) recorded.add(object);
    }

    final source = (await tester.runAsync(
      () => createTestImage(width: 64, height: 64),
    ))!;
    addTearDown(source.dispose);
    FlutterMemoryAllocations.instance.addListener(onEvent);
    addTearDown(
      () => FlutterMemoryAllocations.instance.removeListener(onEvent),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Column(
          children: [
            AppShapedImage(
              image: _Source(source),
              // Sizes nothing else in the suite bakes, so the shared disc mask is recorded here.
              size: 37,
              radius: 18.5,
              errorBuilder: (_) => const SizedBox.shrink(),
            ),
            const AppShapedDisc(color: Color(0xFF336699), size: 37, radius: 9),
          ],
        ),
      ),
    );
    expect(recorded, isNotEmpty);
    FlutterMemoryAllocations.instance.removeListener(onEvent);

    // Two frames of another tree, so every layer of the first has let its picture go.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect([
      for (final picture in recorded)
        if (!picture.debugDisposed) picture,
    ], isEmpty);
  });
}
