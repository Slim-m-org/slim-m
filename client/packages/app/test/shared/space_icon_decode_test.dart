// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The space icon decodes near its painted size, the same way an avatar does;
/// drawn straight from its source it aliased on a scaled desktop.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/space_icon.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets(
    'a 20px icon decodes at 3x a 2x floor and draws with medium filtering',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bytes = Uint8List.fromList(List<int>.filled(16, 1));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            spaceIconBytesProvider(7).overrideWith((ref) async => bytes),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: SpaceIcon(updatedAt: 7, size: 20)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final image = tester.widget<AppShapedImage>(find.byType(AppShapedImage));
      final resized = image.image as ResizeImage;
      expect((resized.imageProvider as MemoryImage).bytes, bytes);
      expect(resized.width, 120);
      expect(resized.height, 120);
      expect(image.filterQuality, FilterQuality.medium);
    },
  );
}
