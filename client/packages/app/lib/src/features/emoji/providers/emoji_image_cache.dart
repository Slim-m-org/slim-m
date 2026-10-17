// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A cache for a deployment's own emoji image bytes that survives an app
/// restart, so reopening the picker on a later launch does not repeat the
/// concurrent-fetch burst [customEmojiImageProvider]'s own doc describes.
///
/// An emoji id never names different bytes once uploaded (there is no edit,
/// only delete-and-reupload under a new id), which is what makes this safe
/// to keep past the session that fetched it: nothing here ever needs
/// invalidating, only evicting once it takes too much room.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Read/write access to cached emoji image bytes, kept behind an interface
/// so a test can hand [customEmojiImageProvider] an in-memory fake rather
/// than touch a real filesystem or a real browser.
abstract interface class EmojiImageCache {
  /// The cached bytes for [emojiId], or null on a miss.
  Future<Uint8List?> read(String emojiId);

  /// Stores [bytes] for [emojiId]. Never throws: a write that fails leaves
  /// the emoji to refetch next launch, which is the same as never having
  /// cached it, not a reason to break the fetch that just succeeded.
  Future<void> write(String emojiId, Uint8List bytes);
}

/// Total bytes [DiskEmojiImageCache] keeps before it starts evicting.
///
/// A deployment may hold up to 500 emoji (`MAX_CUSTOM_EMOJI`,
/// `store/emoji.rs:15`) at up to 1 MiB each (`MAX_IMAGE_BYTES`,
/// `emoji.rs:35`), so caching a full catalog at the ceiling would claim 500
/// MiB of a phone's storage for pictures the server will always re-serve on
/// a miss. Custom emoji are small stickers in practice, not full-size
/// photos, so 32 MiB comfortably holds a realistic catalog whole while
/// still bounding the worst case - a deployment that uploaded nothing but
/// maximum-size images - to a few dozen entries rather than all 500.
@visibleForTesting
const emojiImageCacheByteCeiling = 32 * 1024 * 1024;

/// The subdirectory this cache owns under the app's support directory.
/// Its own directory rather than a loose file among drift's, so clearing it
/// (a future "free up space" action, say) cannot touch anything else there.
const _cacheDirName = 'emoji-image-cache';

/// Disk-backed, least-recently-used by file modification time rather than a
/// separate manifest: touching a file's mtime on every read and write is
/// enough to order eviction correctly and needs no extra state that could
/// itself drift from what is actually on disk.
class DiskEmojiImageCache implements EmojiImageCache {
  DiskEmojiImageCache({Directory? directory}) : _directory = directory;

  /// Overridden by tests; production always resolves the real
  /// application-support directory, the same call `openSlimmDatabase`'s
  /// native backend makes for drift's own file.
  final Directory? _directory;

  Future<Directory>? _dir;

  Future<Directory> _cacheDir() => _dir ??= _open();

  Future<Directory> _open() async {
    final base = _directory ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _cacheDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// `Uri.encodeComponent` rather than the id verbatim: ids are server-issued
  /// UUIDs today with nothing unsafe in them, but a cache file name built
  /// from any external string should not trust that forever, the same
  /// defense-in-depth the API transport's own path-segment escaping applies.
  File _fileFor(Directory dir, String emojiId) =>
      File(p.join(dir.path, '${Uri.encodeComponent(emojiId)}.bin'));

  @override
  Future<Uint8List?> read(String emojiId) async {
    try {
      final file = _fileFor(await _cacheDir(), emojiId);
      final bytes = await file.readAsBytes();
      unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      return bytes;
    } catch (_) {
      // A miss, an unreadable file, or a broken directory: all read as a cache that was never populated.
      return null;
    }
  }

  @override
  Future<void> write(String emojiId, Uint8List bytes) async {
    try {
      final dir = await _cacheDir();
      await _fileFor(dir, emojiId).writeAsBytes(bytes);
      await _evictOverCeiling(dir);
    } catch (_) {
      // See the interface doc: a failed write only means a slower next launch.
    }
  }

  Future<void> _evictOverCeiling(Directory dir) async {
    final files = <File>[];
    final sizes = <File, int>{};
    final modified = <File, DateTime>{};
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      files.add(entity);
      sizes[entity] = stat.size;
      modified[entity] = stat.modified;
      total += stat.size;
    }
    if (total <= emojiImageCacheByteCeiling) return;
    files.sort((a, b) => modified[a]!.compareTo(modified[b]!));
    for (final file in files) {
      if (total <= emojiImageCacheByteCeiling) break;
      total -= sizes[file]!;
      try {
        await file.delete();
      } catch (_) {
        // Left for a later eviction pass; not this write's problem to solve.
      }
    }
  }
}

/// A no-op cache: every read misses, every write is dropped after one debug
/// print. Two callers reach for this rather than [DiskEmojiImageCache]:
///
/// - The web build, which has no filesystem to persist into (see
///   `connection/web.dart`'s own doc for why drift's browser backend needs
///   OPFS/IndexedDB rather than a plain file - the same gap applies here, and
///   adding a second bespoke IndexedDB store just for emoji bytes is not
///   worth it for pictures the server always has).
/// - `emojiImageCacheProvider`'s own default, so a [ProviderContainer] that
///   never wires [createEmojiImageCache] in - every widget test but the ones
///   that ask for the real cache on purpose - never touches `path_provider`
///   at all. That call is a genuine platform channel round trip with no
///   Flutter-provided test double, which does not resolve inside a plain
///   `pumpAndSettle`; seeing that hang, the fix is to keep it out of a
///   container that never opted in, not to demand every such test learn
///   `tester.runAsync` or mock a plugin it never asked to depend on.
///
/// Either way, every emoji still stays cached for the running session
/// through [customEmojiImageProvider] itself; only the "survives a reload"
/// half of the win is missing here, said once so that reads as expected
/// rather than as a regression.
class NoopEmojiImageCache implements EmojiImageCache {
  var _warned = false;

  @override
  Future<Uint8List?> read(String emojiId) async => null;

  @override
  Future<void> write(String emojiId, Uint8List bytes) async {
    if (_warned) return;
    _warned = true;
    debugPrint(
      'slim-m: no persistent emoji cache for this session; images refetch next time',
    );
  }
}

/// The real, on-disk backend for whichever platform can open one: everything
/// but the web build. Not [emojiImageCacheProvider]'s own default - see
/// [NoopEmojiImageCache]'s doc for why - so production wires this in
/// explicitly (`main.dart`) rather than leaving every consumer to discover
/// whether the ambient container happens to have it.
EmojiImageCache createEmojiImageCache() =>
    kIsWeb ? NoopEmojiImageCache() : DiskEmojiImageCache();
