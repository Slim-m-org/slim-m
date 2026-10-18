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

import 'package:cryptography/cryptography.dart';
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

/// Namespaces one server's cached previews so no other server can read or
/// overwrite them, and so signing out can drop exactly that server's files.
String attachmentPreviewScope(Uri server) {
  final digest = Sha256().toSync().hashSync(server.origin.codeUnits).bytes;
  return digest.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Whether [bytes] open with the signature of an image format a decoder takes.
bool looksLikeImage(Uint8List b) {
  bool at(int offset, List<int> sig) =>
      b.length >= offset + sig.length &&
      [
        for (var i = 0; i < sig.length; i++) b[offset + i] == sig[i],
      ].every((m) => m);
  return at(0, [0x89, 0x50, 0x4E, 0x47]) ||
      at(0, [0xFF, 0xD8, 0xFF]) ||
      at(0, [0x47, 0x49, 0x46, 0x38]) ||
      at(0, [0x42, 0x4D]) ||
      (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) ||
      at(4, [0x66, 0x74, 0x79, 0x70]);
}

/// Whether [b] is an image that can animate: any gif, a png with an `acTL`
/// chunk, or a webp with an `ANIM` chunk.
bool looksAnimated(Uint8List b) {
  bool tag(int offset, String t) =>
      b.length >= offset + 4 &&
      String.fromCharCodes(b.sublist(offset, offset + 4)) == t;
  int u32(int offset, Endian endian) =>
      ByteData.sublistView(b).getUint32(offset, endian);
  if (tag(0, 'GIF8')) return true;
  if (tag(0, '\u0089PNG')) {
    // Chunks run [length][type][data][crc]; acTL must precede the first IDAT.
    for (var at = 8; at + 8 <= b.length;) {
      if (tag(at + 4, 'acTL')) return true;
      if (tag(at + 4, 'IDAT')) return false;
      at += 12 + u32(at, Endian.big);
    }
    return false;
  }
  if (tag(0, 'RIFF') && tag(8, 'WEBP')) {
    for (var at = 12; at + 8 <= b.length;) {
      if (tag(at, 'ANIM')) return true;
      at += 8 + u32(at + 4, Endian.little) + (u32(at + 4, Endian.little) & 1);
    }
  }
  return false;
}

/// Forgets every preview cached for [server], when its account goes away.
Future<void> clearAttachmentPreviews(ByteCache cache, Uri server) =>
    cache.removeWithPrefix('${attachmentPreviewScope(server)}-');

typedef AttachmentPreviewKey = ({String id, int bucket});

final attachmentPreviewBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, AttachmentPreviewKey>((ref, key) async {
      final scope = attachmentPreviewScope(ref.watch(serverUrlProvider));
      final cacheKey = '$scope-${key.id}-${key.bucket}';
      _recentPreviews.hold(ref, cacheKey);
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final cache = ref.watch(attachmentPreviewCacheProvider);
      final cached = await cache.read(cacheKey);
      if (cached != null && looksLikeImage(cached)) return cached;
      final api = ref.watch(apiProvider);
      final bytes = await fetchAttachmentRetrying(
        ref,
        () => api.fetchAttachment(key.id, previewWidth: key.bucket),
        isDisposed: () => disposed,
        onGiveUp: () => _recentPreviews.release(cacheKey),
      );
      if (bytes.length <= attachmentPreviewEntryMaxBytes &&
          looksLikeImage(bytes)) {
        unawaited(cache.write(cacheKey, bytes));
      }
      return bytes;
    });
