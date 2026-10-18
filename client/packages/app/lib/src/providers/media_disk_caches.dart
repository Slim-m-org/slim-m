// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Disk caches for the two byte sources that otherwise refetch after eviction
/// or a restart: avatars and attachment originals (a gif, an opened photo).
///
/// Same shape as the preview cache: a no-op by default so a container that
/// never opted in never reaches `path_provider`, and `main.dart` wires the
/// real ones.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/messages/providers/attachment_preview_bytes.dart';
import 'disk_byte_cache.dart';

const avatarCacheBytes = 32 * 1024 * 1024;
const attachmentOriginalCacheBytes = 256 * 1024 * 1024;

/// A larger original is not worth the disk; it refetches like before.
const attachmentOriginalEntryMaxBytes = 16 * 1024 * 1024;

final avatarCacheProvider = Provider<ByteCache>((ref) => NoopByteCache());
final attachmentOriginalCacheProvider = Provider<ByteCache>(
  (ref) => NoopByteCache(),
);

ByteCache createAvatarCache() => kIsWeb
    ? NoopByteCache()
    : DiskByteCache(
        dirName: 'avatars',
        ceilingBytes: avatarCacheBytes,
        extension: 'img',
        trimEveryWrites: 25,
      );

ByteCache createAttachmentOriginalCache() => kIsWeb
    ? NoopByteCache()
    : DiskByteCache(
        dirName: 'attachment-originals',
        ceilingBytes: attachmentOriginalCacheBytes,
        extension: 'bin',
        trimEveryWrites: 5,
      );

/// Namespaces a key under one server, like the preview cache does.
String serverScopedKey(Uri server, String key) =>
    '${attachmentPreviewScope(server)}-$key';

/// Forgets everything cached for [server], when its account goes away.
Future<void> clearMediaDiskCaches(
  Uri server, {
  required ByteCache avatars,
  required ByteCache originals,
}) async {
  final prefix = serverScopedKey(server, '');
  await avatars.removeWithPrefix(prefix);
  await originals.removeWithPrefix(prefix);
}
