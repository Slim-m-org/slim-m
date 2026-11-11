// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/storage/atomic_preferences_store.dart';

import 'preferences_store_contract.dart';

void main() {
  late Directory dir;
  late List<PreferencesReadOutcome> reads;

  AtomicPreferencesStore store() =>
      AtomicPreferencesStore(directory: () async => dir, onRead: reads.add);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('atomic_prefs_');
    reads = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads a file written by the stock plugin unchanged', () async {
    final stock = stockLinuxStore(dir);
    await stock.setValue('String', noiseKey, 'strong');
    await stock.setValue('StringList', 'flutter.list', ['a', 'b']);
    await stock.setValue('Double', 'flutter.ratio', 0.5);

    final all = await store().getAll();

    expect(all, {
      noiseKey: 'strong',
      'flutter.list': ['a', 'b'],
      'flutter.ratio': 0.5,
    });
    expect(reads, isEmpty);
  });

  test('a file it wrote is read back by the stock plugin', () async {
    await store().setValue('String', noiseKey, 'strong');

    expect((await stockLinuxStore(dir).getAll())[noiseKey], 'strong');
  });

  test(
    'writes leave no temp file behind and keep the previous file as .bak',
    () async {
      final first = store();
      await first.setValue('String', noiseKey, 'standard');
      await first.setValue('String', noiseKey, 'strong');

      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(names, {'shared_preferences.json', 'shared_preferences.json.bak'});
      expect(
        (await File('${dir.path}/shared_preferences.json.bak').readAsString()),
        contains('standard'),
      );
    },
  );

  test('recovers from the backup when the main file is missing', () async {
    final first = store();
    await first.setValue('String', noiseKey, 'strong');
    await first.setValue('Bool', otherKey, true);
    prefsFile(dir).deleteSync();

    expect((await store().getAll())[noiseKey], 'strong');
    expect(reads, [PreferencesReadOutcome.restoredFromBackup]);
  });

  test('reports and starts empty when nothing can be recovered', () async {
    prefsFile(dir).writeAsStringSync('{"flutter.sl');

    expect(await store().getAll(), isEmpty);
    expect(reads, [PreferencesReadOutcome.unrecoverable]);
  });

  test('a fresh install is empty without a report', () async {
    expect(await store().getAll(), isEmpty);
    expect(reads, isEmpty);
  });

  test('the next write after a recovery repairs the main file', () async {
    final first = store();
    await first.setValue('String', noiseKey, 'strong');
    await first.setValue('Bool', otherKey, true);
    truncateLikeAKill(dir, toEmpty: false);

    await store().setValue('Bool', 'flutter.more', true);

    final all = await stockLinuxStore(dir).getAll();
    expect(all[noiseKey], 'strong');
    expect(all['flutter.more'], true);
  });

  test('remove drops only that key, even from a stale instance', () async {
    final stale = store();
    await stale.getAll();
    final other = store();
    await other.setValue('String', noiseKey, 'strong');
    await other.setValue('Bool', otherKey, true);

    await stale.remove(otherKey);

    expect(await store().getAll(), {noiseKey: 'strong'});
  });

  test('clear removes only keys under its prefix', () async {
    final s = store();
    await s.setValue('String', noiseKey, 'strong');
    await s.setValue('String', 'plain', 'kept');

    await s.clear();

    expect(await store().getAllWithPrefix(''), {'plain': 'kept'});
  });

  test('concurrent writes from one instance all land', () async {
    final s = store();
    await Future.wait([
      for (var i = 0; i < 20; i++) s.setValue('Int', 'flutter.k$i', i),
    ]);

    expect((await store().getAll()).length, 20);
  });
}
