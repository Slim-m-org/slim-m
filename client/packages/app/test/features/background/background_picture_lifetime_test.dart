// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When the decoded background bitmap is released: never while a widget can
/// still paint it, and not at all once nothing is showing a background.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';

Uint8List get _forest =>
    File('test/fixtures/background_forest.png').readAsBytesSync();

Future<ui.Image> _shown(ProviderContainer c) async {
  final image = await c.read(backgroundPictureProvider.future);
  return image!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'replacing the picture keeps the old bitmap alive until the new one lands',
    () async {
      final c = ProviderContainer(
        overrides: [
          backgroundImageStoreProvider.overrideWithValue(
            MemoryBackgroundImageStore(),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(backgroundPictureProvider, (_, _) {});
      final notifier = c.read(appBackgroundControllerProvider.notifier);

      await notifier.importPicture(_forest);
      final first = await _shown(c);

      await notifier.importPicture(_forest);
      final during = c.read(backgroundPictureProvider);

      expect(during.isLoading, isTrue);
      expect(during.valueOrNull, same(first));
      expect(
        first.debugDisposed,
        isFalse,
        reason: 'a widget still paints it while the replacement decodes',
      );

      final second = await _shown(c);
      expect(second, isNot(same(first)));
      expect(first.debugDisposed, isTrue, reason: 'nothing needs it any more');
      expect(second.debugDisposed, isFalse);
    },
  );

  test('a background nobody is showing does not keep its bitmap', () async {
    final c = ProviderContainer(
      overrides: [
        backgroundImageStoreProvider.overrideWithValue(
          MemoryBackgroundImageStore(),
        ),
      ],
    );
    addTearDown(c.dispose);
    final subscription = c.listen(backgroundPictureProvider, (_, _) {});
    await c
        .read(appBackgroundControllerProvider.notifier)
        .importPicture(_forest);
    final image = await _shown(c);
    expect(image.debugDisposed, isFalse);

    subscription.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(image.debugDisposed, isTrue);
  });

  test('removing the picture releases the bitmap', () async {
    final c = ProviderContainer(
      overrides: [
        backgroundImageStoreProvider.overrideWithValue(
          MemoryBackgroundImageStore(),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(backgroundPictureProvider, (_, _) {});
    final notifier = c.read(appBackgroundControllerProvider.notifier);
    await notifier.importPicture(_forest);
    final image = await _shown(c);

    await notifier.remove();
    expect(await c.read(backgroundPictureProvider.future), isNull);

    expect(image.debugDisposed, isTrue);
  });
}
