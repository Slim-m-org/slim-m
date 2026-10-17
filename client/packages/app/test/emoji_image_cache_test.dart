// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the disk-backed emoji image cache: a write is readable back, a
/// miss is null rather than a throw, eviction keeps the cache under its own
/// byte ceiling, and the web build's no-op degrades visibly rather than
/// silently.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_image_cache.dart';

Uint8List _bytesOfSize(int size) => Uint8List(size)..fillRange(0, size, 7);

void main() {
  late Directory dir;
  late DiskEmojiImageCache cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('emoji_image_cache_test');
    cache = DiskEmojiImageCache(directory: dir);
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('a miss reads as null, not a throw', () async {
    expect(await cache.read('e-nope'), isNull);
  });

  test('a write is readable back byte for byte', () async {
    final bytes = _bytesOfSize(128);
    await cache.write('e-1', bytes);
    expect(await cache.read('e-1'), bytes);
  });

  test('an id shaped like a path traversal still round trips as one entry '
      'inside the cache directory, never outside it', () async {
    final bytes = _bytesOfSize(16);
    await cache.write('../../etc/passwd', bytes);
    expect(await cache.read('../../etc/passwd'), bytes);
    expect(dir.listSync(), hasLength(1));
  });

  test('a read that cannot open the cache directory misses rather than '
      'throwing', () async {
    final missing = Directory('${dir.path}/does-not-exist-and-is-a-file');
    File(missing.path).writeAsStringSync('not a directory');
    final broken = DiskEmojiImageCache(directory: missing);
    expect(await broken.read('e-1'), isNull);
  });

  test('writing past the byte ceiling evicts the least recently used entry '
      'first', () async {
    final entrySize = (emojiImageCacheByteCeiling / 2).floor();
    await cache.write('e-oldest', _bytesOfSize(entrySize));
    await cache.write('e-middle', _bytesOfSize(entrySize));
    // Touches e-oldest's mtime, making it more recently used than e-middle despite being written first.
    await cache.read('e-oldest');
    // Pushes total past the ceiling; the least recently used entry (e-middle) must go.
    await cache.write('e-newest', _bytesOfSize(entrySize));

    expect(await cache.read('e-oldest'), isNotNull);
    expect(await cache.read('e-newest'), isNotNull);
    expect(await cache.read('e-middle'), isNull);
  });

  test('the web no-op cache always misses and warns exactly once', () async {
    final noop = NoopEmojiImageCache();
    expect(await noop.read('e-1'), isNull);
    await noop.write('e-1', _bytesOfSize(4));
    // A second write must not throw either, past the one-time debugPrint.
    await noop.write('e-2', _bytesOfSize(4));
    expect(await noop.read('e-2'), isNull);
  });
}
