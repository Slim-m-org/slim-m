// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What Appearance's captures and geometry tests share: a background picture.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/background/providers/background_tone.dart';

/// A forest picture behind the panes, dimmed 70% and blurred 20%.
Future<List<Override>> backgroundPictureOverrides(WidgetTester tester) async {
  final bytes = File('test/fixtures/background_forest.png').readAsBytesSync();
  final prepared = await tester.runAsync(
    () => prepareBackground(
      bytes,
      maxSide: backgroundMaxSide,
      maxSourcePixels: backgroundMaxSourcePixels,
    ),
  );
  final store = MemoryBackgroundImageStore();
  await tester.runAsync(() => store.write(prepared!.png));
  return [
    backgroundImageStoreProvider.overrideWithValue(store),
    appBackgroundControllerProvider.overrideWith(
      () => AppBackgroundController(
        AppBackgroundSettings(
          hasImage: true,
          range: prepared!.range,
          dim: 0.7,
          blur: 0.2,
        ),
      ),
    ),
  ];
}
