// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and caches one user's profile banner bytes, keyed by
/// (userId, bannerUpdatedAt) like an avatar so a new upload refetches itself.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/media_disk_caches.dart';
import '../../../providers/providers.dart';

typedef BannerKey = ({String userId, int updatedAt});

final _recent = KeepAliveCache(24);

/// Null when the user has no banner (a 404) and while the fetch is in flight.
final bannerBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, BannerKey>((ref, key) async {
      _recent.hold(ref, key);
      final cache = ref.watch(avatarCacheProvider);
      final diskKey = serverScopedKey(
        ref.watch(serverUrlProvider),
        'banner-${key.userId}-${key.updatedAt}',
      );
      final cached = await cache.read(diskKey);
      if (cached != null) return cached;
      try {
        final fetched = await ref.watch(apiProvider).fetchBanner(key.userId);
        unawaited(cache.write(diskKey, fetched.bytes));
        return fetched.bytes;
      } on NotFoundException catch (error, stack) {
        AppLog.swallowed(LogTag.media, 'This user has no banner', error, stack);
        return null;
      }
    });
