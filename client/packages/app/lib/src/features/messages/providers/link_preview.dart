// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and caches a pasted URL's unfurled preview, and its image bytes.
///
/// Both no-op when the deployment has not enabled link previews
/// (`Version.linkPreviewsEnabled`), so a disabled server costs nothing: no
/// request, and the transcript renders no card. In-memory only and
/// `autoDispose`, the same tradeoff `avatar_bytes.dart` and
/// `attachment_bytes.dart` make.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/server_info.dart';
import '../../../providers/cache_for.dart';
import '../../../providers/providers.dart';
import 'attachment_bytes.dart' show fetchRetrying;

/// Held past the last watcher, sized past a transcript pane's worth of
/// linked messages, so an ordinary scroll does not refetch every card.
final _recentPreviews = KeepAliveCache(256);
final _recentImages = KeepAliveCache(128);

/// Links whose preview was refetched for a stale image token, so a token
/// that stays dead (the image really is gone) costs one refetch, not a loop.
/// Follows the API client, so another server or account starts over.
final refreshedStalePreviewsProvider = Provider<Set<String>>((ref) {
  ref.watch(apiProvider);
  return <String>{};
});

/// Null both when the deployment has not enabled link previews and when the
/// URL yielded no usable preview - a caller cannot tell those apart from
/// this alone, but in both cases the answer is the same: render nothing.
final linkPreviewProvider = FutureProvider.autoDispose
    .family<LinkPreview?, String>((ref, url) async {
      _recentPreviews.hold(ref, url);
      final enabled = ref.watch(
        serverInfoProvider.select(
          (info) => info.valueOrNull?.linkPreviewsEnabled ?? false,
        ),
      );
      if (!enabled) return null;
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final api = ref.watch(apiProvider);
      return fetchRetrying(
        ref,
        () => api.fetchLinkPreview(url),
        isDisposed: () => disposed,
        // A cached failure would replay for every later view of this link.
        onGiveUp: () => _recentPreviews.release(url),
      );
    });

/// A preview's proxied image bytes, keyed by its `imageToken`. Null on a
/// stale token (a 404), the same fallback `avatarBytesProvider` makes.
final linkPreviewImageBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, token) async {
      _recentImages.hold(ref, token);
      var disposed = false;
      ref.onDispose(() => disposed = true);
      final api = ref.watch(apiProvider);
      try {
        final fetched = await fetchRetrying(
          ref,
          () => api.fetchLinkPreviewImage(token),
          isDisposed: () => disposed,
        );
        return fetched.bytes;
      } on NotFoundException catch (error, stack) {
        AppLog.swallowed(
          LogTag.ui,
          'The link preview image is gone',
          error,
          stack,
        );
        return null;
      } catch (_) {
        // A cached failure would replay for every later view of this image.
        _recentImages.release(token);
        rethrow;
      }
    });
