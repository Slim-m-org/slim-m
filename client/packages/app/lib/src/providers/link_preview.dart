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

import '../widgets/channel_rail_frame.dart' show serverInfoProvider;
import 'cache_for.dart';
import 'providers.dart';

/// Held past the last watcher, sized past a transcript pane's worth of
/// linked messages, so an ordinary scroll does not refetch every card.
final _recentPreviews = KeepAliveCache(256);
final _recentImages = KeepAliveCache(128);

/// Null both when the deployment has not enabled link previews and when the
/// URL yielded no usable preview - a caller cannot tell those apart from
/// this alone, but in both cases the answer is the same: render nothing.
final linkPreviewProvider = FutureProvider.autoDispose
    .family<LinkPreview?, String>((ref, url) async {
      _recentPreviews.hold(ref, url);
      final enabled =
          ref.watch(serverInfoProvider).valueOrNull?.linkPreviewsEnabled ??
          false;
      if (!enabled) return null;
      return ref.watch(apiProvider).fetchLinkPreview(url);
    });

/// A preview's proxied image bytes, keyed by its `imageToken`. Null on a
/// stale token (a 404), the same fallback `avatarBytesProvider` makes.
final linkPreviewImageBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, token) async {
      _recentImages.hold(ref, token);
      try {
        final fetched = await ref
            .watch(apiProvider)
            .fetchLinkPreviewImage(token);
        return fetched.bytes;
      } on NotFoundException {
        return null;
      }
    });
