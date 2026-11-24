// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An in-memory stand-in for the disk caches, shared by the cache tests.
library;

import 'dart:typed_data';

import 'package:slimm_app/src/features/emoji/providers/emoji_image_cache.dart';
import 'package:slimm_app/src/providers/disk_byte_cache.dart';

class MemoryByteCache implements ByteCache, EmojiImageCache {
  final entries = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => entries[key];

  @override
  Future<void> write(String key, Uint8List bytes) async => entries[key] = bytes;

  @override
  Future<void> removeWithPrefix(String prefix) async =>
      entries.removeWhere((key, _) => key.startsWith(prefix));
}
