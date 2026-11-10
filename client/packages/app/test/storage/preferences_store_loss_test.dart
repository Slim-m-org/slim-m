// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'preferences_store_contract.dart';

final _stores = <String, StoreFactory>{'stock linux plugin': stockLinuxStore};

void main() {
  for (final entry in _stores.entries) {
    group('${entry.key} keeps settings', () {
      late Directory dir;

      setUp(() => dir = Directory.systemTemp.createTempSync('prefs_loss_'));
      tearDown(() => dir.deleteSync(recursive: true));

      for (final toEmpty in [true, false]) {
        test(
          'after a kill leaves the file ${toEmpty ? 'empty' : 'truncated'}',
          () async {
            final writer = entry.value(dir);
            await writer.setValue('String', noiseKey, 'strong');
            await writer.setValue('Bool', otherKey, true);
            truncateLikeAKill(dir, toEmpty: toEmpty);

            final reader = entry.value(dir);
            expect((await reader.getAll())[noiseKey], 'strong');
          },
        );
      }

      test('when an older instance writes after a newer one', () async {
        final newer = entry.value(dir);
        final stale = entry.value(dir);
        await newer.getAll();
        await stale.getAll();

        await newer.setValue('String', noiseKey, 'strong');
        await stale.setValue('Bool', otherKey, false);

        final fresh = await entry.value(dir).getAll();
        expect(fresh[noiseKey], 'strong');
        expect(fresh[otherKey], false);
      });
    });
  }
}
