// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and caches one attachment's raw bytes.
///
/// In-memory only, per session: an attachment is content-addressed and
/// immutable once uploaded, so there is nothing to invalidate, but caching
/// it to disk on top of the server's own storage was not worth the extra
/// surface for what a self-hosted friend group's message history holds.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'cache_for.dart';
import 'providers.dart';

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

final attachmentBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, attachmentId) async {
      // Far fewer than the avatars': an attachment can be megabytes.
      _recent.hold(ref, attachmentId);
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final api = ref.watch(apiProvider);
      final delays = ref.read(attachmentRetryDelaysProvider);
      for (var attempt = 0; ; attempt++) {
        try {
          final fetched = await api.fetchAttachment(attachmentId);
          return fetched.bytes;
        } catch (error) {
          final retry =
              attempt < delays.length &&
              isTransientAttachmentFailure(error) &&
              !disposed;
          if (!retry) {
            // A cached failure would replay for every later view of this image.
            _recent.release(attachmentId);
            rethrow;
          }
          await Future<void>.delayed(_waitBefore(error, delays[attempt]));
          if (disposed) rethrow;
        }
      }
    });
