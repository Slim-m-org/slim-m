// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A theme file's picture settings are applied only along with its picture,
/// and the Background card is told which theme they came with.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/settings/providers/background_from_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store_actions.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_design_system/design_system.dart';

ThemeDocument get _document => ThemeDocument.of(
  AppTokens.forest,
  name: 'Pine',
  author: 'Ren',
  base: 'forest',
  brightness: Brightness.dark,
  picture: const ThemePicture(dim: 0.9, vignette: false, blur: 0.8),
);

Future<(ProviderContainer, WidgetRef)> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      backgroundImageStoreProvider.overrideWithValue(
        MemoryBackgroundImageStore(),
      ),
    ],
  );
  addTearDown(container.dispose);
  late WidgetRef captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return (container, captured);
}

void main() {
  testWidgets(
    'a picture that cannot be imported applies none of its settings',
    (tester) async {
      final (container, ref) = await _pump(tester);

      await tester.runAsync(
        () => applyThemeDocument(
          ref,
          _document,
          source: const FileThemeSource(),
          pictureBytes: Uint8List.fromList([1, 2, 3, 4]),
        ),
      );

      final s = container.read(appBackgroundControllerProvider);
      expect(
        (s.hasImage, s.dim, s.vignette, s.blur),
        (false, kBackgroundDefaultDim, true, 0.0),
      );
      expect(container.read(backgroundFromThemeProvider), isNull);
    },
  );

  testWidgets('a picture that becomes the background names its theme', (
    tester,
  ) async {
    final (container, ref) = await _pump(tester);
    final bytes = File('test/fixtures/background_forest.png').readAsBytesSync();

    await tester.runAsync(
      () => applyThemeDocument(
        ref,
        _document,
        source: const SpaceThemeSource('pine'),
        pictureBytes: bytes,
      ),
    );

    final s = container.read(appBackgroundControllerProvider);
    expect((s.hasImage, s.vignette, s.blur), (true, false, 0.8));
    expect(container.read(backgroundFromThemeProvider), 'Pine');
  });

  testWidgets('without the background it leaves the background alone', (
    tester,
  ) async {
    final (container, ref) = await _pump(tester);
    final before = container.read(appBackgroundControllerProvider);

    await tester.runAsync(
      () => applyThemeDocument(
        ref,
        _document,
        source: const SpaceThemeSource('pine'),
        background: false,
      ),
    );

    expect(container.read(appBackgroundControllerProvider), before);
    expect(container.read(backgroundFromThemeProvider), isNull);
  });
}
