// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Writes that overlap never share a temp file, so each lands whole.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/disk_byte_cache.dart';

void main() {
  test('overlapping writes of different keys both land intact', () async {
    final dir = Directory.systemTemp.createTempSync('byte-cache-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskByteCache(
      dirName: 'avatars',
      ceilingBytes: 1 << 30,
      directory: dir,
    );
    final big = {
      for (var i = 0; i < 8; i++)
        'k$i': Uint8List(300000)..fillRange(0, 300000, i + 1),
    };

    await Future.wait([
      for (final entry in big.entries) cache.write(entry.key, entry.value),
      for (final entry in big.entries) cache.write(entry.key, entry.value),
    ]);

    for (final entry in big.entries) {
      expect(await cache.read(entry.key), entry.value, reason: entry.key);
    }
    final leftovers = Directory(
      '${dir.path}/avatars',
    ).listSync().where((e) => e.path.endsWith('.part'));
    expect(leftovers, isEmpty);
  });

  test('a write that cannot land leaves no partial file behind', () async {
    final dir = Directory.systemTemp.createTempSync('byte-cache-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = DiskByteCache(
      dirName: 'avatars',
      ceilingBytes: 1 << 30,
      directory: dir,
    );
    await Directory('${dir.path}/avatars/blocked.bin').create(recursive: true);

    await cache.write('blocked', Uint8List.fromList([1, 2, 3]));

    final leftovers = Directory(
      '${dir.path}/avatars',
    ).listSync().where((e) => e.path.endsWith('.part'));
    expect(leftovers, isEmpty);
  });
}
