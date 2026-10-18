// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bounded-size preview an inline image tile draws, fetched once and kept
/// on disk, so scrolling a photo-heavy channel or reopening the app does not
/// download the originals again.
///
/// The server answers the original when it cannot or need not shrink an image,
/// so these bytes are always something an image decoder can draw.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/disk_byte_cache.dart';
import '../../../providers/providers.dart';
import 'attachment_bytes.dart';

/// Longest-side widths the server rounds a preview up to; keep in step with
/// the buckets documented on `getAttachment`.
const attachmentPreviewBuckets = [320, 640, 1280];

/// The bucket that covers [pixels], so a request names one of a few sizes and
/// the disk cache holds one file per size rather than one per screen.
int attachmentPreviewBucket(int pixels) {
  for (final bucket in attachmentPreviewBuckets) {
    if (pixels <= bucket) return bucket;
  }
  return attachmentPreviewBuckets.last;
}

/// Disk budget for previews; a preview is around 100 KB.
const attachmentPreviewCacheBytes = 256 * 1024 * 1024;

/// A response past this is an original the server could not shrink (a gif, say), not worth disk.
const attachmentPreviewEntryMaxBytes = 2 * 1024 * 1024;

/// Defaults to a no-op so a container that never opted in never reaches
/// `path_provider`; `main.dart` wires the real one.
final attachmentPreviewCacheProvider = Provider<ByteCache>(
  (ref) => NoopByteCache(),
);

ByteCache createAttachmentPreviewCache() => kIsWeb
    ? NoopByteCache()
    : DiskByteCache(
        dirName: 'attachment-previews',
        ceilingBytes: attachmentPreviewCacheBytes,
        extension: 'img',
        trimEveryWrites: 25,
      );

/// Previews are around a hundred times smaller than originals.
final _recentPreviews = KeepAliveCache(48);

typedef AttachmentPreviewKey = ({String id, int bucket});

final attachmentPreviewBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, AttachmentPreviewKey>((ref, key) async {
      final cacheKey = '${key.id}-${key.bucket}';
      _recentPreviews.hold(ref, cacheKey);
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final cache = ref.watch(attachmentPreviewCacheProvider);
      final cached = await cache.read(cacheKey);
      if (cached != null) return cached;
      final api = ref.watch(apiProvider);
      final bytes = await fetchAttachmentRetrying(
        ref,
        () => api.fetchAttachment(key.id, previewWidth: key.bucket),
        isDisposed: () => disposed,
        onGiveUp: () => _recentPreviews.release(cacheKey),
      );
      if (bytes.length <= attachmentPreviewEntryMaxBytes) {
        unawaited(cache.write(cacheKey, bytes));
      }
      return bytes;
    });
