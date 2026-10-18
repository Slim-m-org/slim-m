// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and caches one attachment's raw bytes.
///
/// An attachment is immutable once uploaded, so there is nothing to
/// invalidate: a small original is kept on disk by `media_disk_caches.dart`
/// and survives eviction and a restart. This is the original, fetched when a
/// gif plays or an image is opened, copied or saved.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/media_disk_caches.dart';
import '../../../providers/providers.dart';

/// Deliberately small next to the avatar cache: these are whole images, and
/// the point is surviving a switch away and back rather than holding a
/// channel's history.
final _recent = KeepAliveCache(12);

/// Waits between automatic retries of a transient failure; its length is the
/// retry count. Overridable so a test does not sit through real backoff.
final attachmentRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => const [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
  ],
);

const _longestRateLimitWait = Duration(seconds: 30);

/// Whether the same request could succeed a moment later. A 403 or an
/// explained 404 is the server's answer and stays one.
bool isTransientAttachmentFailure(Object error) => switch (error) {
  TransportException() || UnavailableException() => true,
  RateLimitedException() => true,
  ServerException(:final statusCode) => statusCode >= 500,
  NotFoundException(:final unexplained) => unexplained,
  _ => false,
};

Duration _waitBefore(Object error, Duration backoff) {
  if (error is! RateLimitedException) return backoff;
  final asked = error.retryAfter;
  if (asked == null || asked < backoff) return backoff;
  return asked > _longestRateLimitWait ? _longestRateLimitWait : asked;
}

/// Fetches with [attachmentRetryDelaysProvider]'s waits between attempts on a
/// transient failure; [isDisposed] stops the waiting once nobody is watching.
Future<Uint8List> fetchAttachmentRetrying(
  Ref ref,
  Future<FetchedBytes> Function() fetch, {
  required bool Function() isDisposed,
  required void Function() onGiveUp,
}) async {
  final delays = ref.read(attachmentRetryDelaysProvider);
  for (var attempt = 0; ; attempt++) {
    try {
      return (await fetch()).bytes;
    } catch (error) {
      final retry =
          attempt < delays.length &&
          isTransientAttachmentFailure(error) &&
          !isDisposed();
      if (!retry) {
        onGiveUp();
        rethrow;
      }
      await Future<void>.delayed(_waitBefore(error, delays[attempt]));
      if (isDisposed()) rethrow;
    }
  }
}

final attachmentBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, attachmentId) async {
      // Far fewer than the avatars': an attachment can be megabytes.
      _recent.hold(ref, attachmentId);
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final cache = ref.watch(attachmentOriginalCacheProvider);
      final key = serverScopedKey(ref.watch(serverUrlProvider), attachmentId);
      final cached = await cache.read(key);
      if (cached != null) return cached;
      final api = ref.watch(apiProvider);
      final bytes = await fetchAttachmentRetrying(
        ref,
        () => api.fetchAttachment(attachmentId),
        isDisposed: () => disposed,
        // A cached failure would replay for every later view of this image.
        onGiveUp: () => _recent.release(attachmentId),
      );
      if (bytes.length <= attachmentOriginalEntryMaxBytes) {
        unawaited(cache.write(key, bytes));
      }
      return bytes;
    });
