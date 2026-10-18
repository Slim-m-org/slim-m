// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The image-cache limit setting: default matches Flutter's own, a choice is
/// applied to the live cache and persisted, and a restore reapplies it.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/image_cache_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';

int get _liveCapMb =>
    PaintingBinding.instance.imageCache.maximumSizeBytes >> 20;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the default is 100 MB, matching Flutter\'s own', () {
    final c = container();
    expect(c.read(imageCacheLimitControllerProvider), 100);
    expect(_liveCapMb, 100);
  });

  test(
    'selecting a lower cap applies it to the live cache and persists',
    () async {
      final c = container();
      await c.read(imageCacheLimitControllerProvider.notifier).select(50);

      expect(c.read(imageCacheLimitControllerProvider), 50);
      expect(_liveCapMb, 50);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(imageCacheLimitKey), 50);
    },
  );

  test('restore reapplies a persisted cap to the live cache', () async {
    SharedPreferences.setMockInitialValues({imageCacheLimitKey: 200});
    final c = container();
    await c.read(imageCacheLimitControllerProvider.notifier).restore();

    expect(c.read(imageCacheLimitControllerProvider), 200);
    expect(_liveCapMb, 200);
  });

  test(
    'no limit lifts both the byte and the entry cap, and back again',
    () async {
      final c = container();
      final notifier = c.read(imageCacheLimitControllerProvider.notifier);
      final cache = PaintingBinding.instance.imageCache;

      await notifier.select(imageCacheNoLimitMb);
      expect(cache.maximumSizeBytes, greaterThan(1 << 40));
      expect(cache.maximumSize, greaterThan(1 << 20));
      expect(
        (await SharedPreferences.getInstance()).getInt(imageCacheLimitKey),
        imageCacheNoLimitMb,
      );

      await notifier.select(1000);
      expect(_liveCapMb, 1000);
      expect(cache.maximumSize, 1000);
    },
  );

  test('every choice has a plain label', () {
    expect(imageCacheLimitChoicesMb.map(imageCacheLimitLabel), [
      '50 MB',
      '100 MB (default)',
      '200 MB',
      '500 MB',
      '1 GB',
      'No limit',
    ]);
  });

  test('an unknown persisted value is ignored, leaving the default', () async {
    SharedPreferences.setMockInitialValues({imageCacheLimitKey: 4096});
    final c = container();
    await c.read(imageCacheLimitControllerProvider.notifier).restore();

    expect(c.read(imageCacheLimitControllerProvider), 100);
  });
}
