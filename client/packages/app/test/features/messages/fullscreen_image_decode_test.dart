// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fullscreen viewer decodes a large animation at the screen's size, not
/// the source's, while a still keeps every pixel for zooming.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_page.dart';
import 'package:slimm_design_system/design_system.dart';

final _gif = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<ImageProvider> _provider(WidgetTester tester, Uint8List bytes) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: FullscreenImagePage(
          filename: 'x',
          bytes: bytes,
          onDismiss: () {},
          onZoomChanged: (_) {},
        ),
      ),
    ),
  );
  return tester.widget<Image>(find.byType(Image)).image;
}

void main() {
  testWidgets('an animation is decoded no wider than the screen', (
    tester,
  ) async {
    final image = await _provider(tester, Uint8List.fromList(_gif));

    expect(image, isA<ResizeImage>());
    expect((image as ResizeImage).width, 800);
  });

  testWidgets('a still keeps its pixels for zooming', (tester) async {
    final image = await _provider(tester, Uint8List.fromList(_png));

    expect(image, isNot(isA<ResizeImage>()));
  });
}
