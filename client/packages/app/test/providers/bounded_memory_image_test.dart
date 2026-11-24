// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A picture that declares more pixels than a screen could use is refused
/// before any bitmap is allocated, on every surface that draws sender bytes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/bounded_image_decode.dart';

import '../support/declared_size_png.dart';

Future<Object?> _errorOf(WidgetTester tester, ImageProvider provider) async {
  Object? error;
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) => info.dispose(),
    onError: (e, _) => error = e,
  );
  stream.addListener(listener);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  stream.removeListener(listener);
  return error;
}

void main() {
  testWidgets('a 50000 x 50000 canvas is refused as too large', (tester) async {
    final error = await _errorOf(
      tester,
      ResizeImage(BoundedMemoryImage(declaredSizePng(50000, 50000)), width: 64),
    );
    expect(error, isA<ImageTooLargeException>());
  });

  testWidgets('an ordinary picture still decodes', (tester) async {
    final error = await _errorOf(
      tester,
      ResizeImage(BoundedMemoryImage(solidPng(40, 20)), width: 16),
    );
    expect(error, isNull);
  });
}
