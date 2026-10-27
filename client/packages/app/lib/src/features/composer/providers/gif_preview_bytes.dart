// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and caches one GIF search result's thumbnail bytes, streamed
/// through this deployment's own server rather than a client asking the
/// provider's CDN directly.
///
/// In-memory only, per session, the same tradeoff `attachment_bytes.dart`
/// makes: a token expires server-side within minutes anyway, so there is
/// nothing worth persisting past this session.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/providers.dart';

/// One result grid's worth of thumbnails, generously sized for a full page
/// of search results without holding on to a previous search's images too.
final _recent = KeepAliveCache(48);

/// A result token and the channel the GIF is headed for.
typedef GifPreviewKey = ({String gifId, String? channelId});

final gifPreviewBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, GifPreviewKey>((ref, key) async {
      _recent.hold(ref, key.gifId);
      final fetched = await ref
          .watch(apiProvider)
          .fetchGifPreview(key.gifId, channelId: key.channelId);
      return fetched.bytes;
    });
