// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reused AppShapedImage must not paint the previous picture, or keep its
/// failure, while a different provider is still loading.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

class _Ready extends ImageProvider<_Ready> {
  const _Ready(this.image);

  final ui.Image image;

  @override
  Future<_Ready> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Ready key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: image.clone())),
      );
}

class _Pending extends ImageProvider<_Pending> {
  const _Pending();

  @override
  Future<_Pending> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Pending key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

class _Broken extends ImageProvider<_Broken> {
  const _Broken();

  @override
  Future<_Broken> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Broken key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(
        Future<ImageInfo>.error(StateError('no image')),
      );
}

Widget _shaped(ImageProvider image) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: AppShapedImage(
        image: image,
        size: 40,
        radius: 20,
        errorBuilder: (_) => const Text('broken'),
      ),
    );

final _paint = find.descendant(
  of: find.byType(AppShapedImage),
  matching: find.byType(CustomPaint),
);

void main() {
  testWidgets('a new provider does not paint the old picture while it loads', (
    tester,
  ) async {
    final source = (await tester.runAsync(
      () => createTestImage(width: 64, height: 64),
    ))!;
    addTearDown(source.dispose);

    await tester.pumpWidget(_shaped(_Ready(source)));
    expect(_paint, findsOneWidget);

    await tester.pumpWidget(_shaped(const _Pending()));
    expect(_paint, findsNothing);
  });

  testWidgets('a new provider does not keep the old one\'s failure', (
    tester,
  ) async {
    await tester.pumpWidget(_shaped(const _Broken()));
    await tester.pump();
    expect(find.text('broken'), findsOneWidget);

    await tester.pumpWidget(_shaped(const _Pending()));
    expect(find.text('broken'), findsNothing);
  });
}
