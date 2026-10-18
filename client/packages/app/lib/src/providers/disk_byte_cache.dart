// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A size-capped, least-recently-used cache of byte blobs on disk, for content
/// that never changes once fetched (an emoji image, an attachment preview), so
/// nothing here is ever invalidated, only evicted.
///
/// Recency is each file's modification time, touched on every read and write,
/// which needs no manifest that could drift from what is on disk.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, ignoreError;

/// Keyed byte storage whose reads and writes never throw: a failure only
/// means the next view refetches.
abstract interface class ByteCache {
  /// The cached bytes for [key], or null on a miss.
  Future<Uint8List?> read(String key);

  /// Stores [bytes] under [key], or drops them if the disk will not take them.
  Future<void> write(String key, Uint8List bytes);

  /// Drops every entry whose key starts with [prefix].
  Future<void> removeWithPrefix(String prefix);
}

/// Keeps [ceilingBytes] of files under [dirName] in the application support
/// directory (or [directory], for a test), evicting the stalest first.
class DiskByteCache implements ByteCache {
  DiskByteCache({
    required this.dirName,
    required this.ceilingBytes,
    this.extension = 'bin',
    this.trimEveryWrites = 1,
    Directory? directory,
  }) : _directory = directory;

  final String dirName;
  final int ceilingBytes;
  final String extension;

  /// Eviction scans the whole directory, so a cache of many small files runs
  /// it once per this many writes and overshoots by at most as many entries.
  final int trimEveryWrites;
  final Directory? _directory;

  Future<Directory>? _dir;
  var _writesSinceTrim = 0;
  var _trimmedOnce = false;

  Future<Directory> _cacheDir() => _dir ??= _open();

  Future<Directory> _open() async {
    final base = _directory ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, dirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Escaped so a key built from any external string stays inside [dirName].
  File _fileFor(Directory dir, String key) =>
      File(p.join(dir.path, '${Uri.encodeComponent(key)}.$extension'));

  @override
  Future<Uint8List?> read(String key) async {
    try {
      final file = _fileFor(await _cacheDir(), key);
      final bytes = await file.readAsBytes();
      unawaited(
        file
            .setLastModified(DateTime.now())
            .catchError(
              ignoreError(
                LogTag.media,
                'touching the cache entry is best effort',
              ),
            ),
      );
      return bytes;
    } catch (error, stack) {
      AppLog.swallowed(LogTag.media, 'read failed, ignored', error, stack);
      // A miss, an unreadable file or a broken directory all read as never cached.
      return null;
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    try {
      final dir = await _cacheDir();
      final file = _fileFor(dir, key);
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes);
      await partial.rename(file.path);
      if (_dueForTrim()) await _evictOverCeiling(dir);
    } catch (error, stack) {
      AppLog.swallowed(LogTag.media, 'write failed, ignored', error, stack);
      // See [ByteCache.write]: a failed write is a slower next view, nothing more.
    }
  }

  @override
  Future<void> removeWithPrefix(String prefix) async {
    try {
      final encoded = Uri.encodeComponent(prefix);
      await for (final entity in (await _cacheDir()).list()) {
        if (entity is File && p.basename(entity.path).startsWith(encoded)) {
          await entity.delete();
        }
      }
    } catch (_) {
      // An undeletable file stays until eviction reaches it.
    }
  }

  bool _dueForTrim() {
    _writesSinceTrim++;
    if (_trimmedOnce && _writesSinceTrim < trimEveryWrites) return false;
    _trimmedOnce = true;
    _writesSinceTrim = 0;
    return true;
  }

  Future<void> _evictOverCeiling(Directory dir) async {
    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      entries.add((file: entity, size: stat.size, modified: stat.modified));
      total += stat.size;
    }
    if (total <= ceilingBytes) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= ceilingBytes) break;
      total -= entry.size;
      try {
        await entry.file.delete();
      } catch (error, stack) {
        AppLog.swallowed(
          LogTag.media,
          'evict over ceiling failed, ignored',
          error,
          stack,
        );
        // Left for a later pass.
      }
    }
  }
}

/// Caches nothing: the web build has no filesystem to keep bytes on, and a
/// container that never opts into the real cache never reaches `path_provider`.
class NoopByteCache implements ByteCache {
  @override
  Future<Uint8List?> read(String key) async => null;

  @override
  Future<void> write(String key, Uint8List bytes) async {}

  @override
  Future<void> removeWithPrefix(String prefix) async {}
}
