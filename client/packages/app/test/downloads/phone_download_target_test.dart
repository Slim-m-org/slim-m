// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone download lives in a cache file while it streams and is handed to the save step whole.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/download_target_phone.dart';

void main() {
  late Directory cache;
  late List<(List<int>, String)> saved;
  var answer = true;
  var explode = false;

  Future<PhoneDownloadTarget> open(String name) => PhoneDownloadTarget.open(
    name,
    cache: cache,
    saver: (file, filename) async {
      saved.add((await file.readAsBytes(), filename));
      if (explode) throw StateError('no picker');
      return answer;
    },
  );

  List<FileSystemEntity> leftovers() => Directory(
    '${cache.path}/phone-saves',
  ).listSync().whereType<Directory>().toList();

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('slimm-phone-target');
    addTearDown(() => cache.delete(recursive: true));
    saved = [];
    answer = true;
    explode = false;
  });

  test('chunks reach disk as they arrive, with no size limit', () async {
    final target = await open('movie.mkv');
    await target.write(List.filled(1024, 7));
    await target.write(List.filled(1024, 8));

    expect(target.maxBytes, isNull);
    final onDisk = cache
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.lengthSync())
        .fold<int>(0, (a, b) => a + b);
    expect(onDisk, 2048, reason: 'the bytes are in a cache file, not memory');

    expect(await target.finish(), isTrue);
    expect(saved.single.$1.length, 2048);
    expect(saved.single.$2, 'movie.mkv');
    expect(leftovers(), isEmpty);
  });

  test('a dismissed save step reports false and keeps nothing', () async {
    answer = false;
    final target = await open('a.txt');
    await target.write([1]);

    expect(await target.finish(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('a save step that throws still clears the cache copy', () async {
    explode = true;
    final target = await open('a.txt');
    await target.write([1]);

    await expectLater(target.finish(), throwsStateError);
    expect(leftovers(), isEmpty);
  });

  test('a discard removes the partial and the cache folder', () async {
    final target = await open('a.txt');
    await target.write([1, 2, 3]);

    await target.discard();

    expect(leftovers(), isEmpty);
    expect(
      cache.listSync(recursive: true).whereType<File>(),
      isEmpty,
      reason: 'no partial file is left behind',
    );
  });

  test('a name from the server cannot leave the cache folder', () async {
    final target = await open('../../etc/passwd');
    await target.write([1]);

    await target.finish();

    expect(saved.single.$2, 'passwd');
  });
}
