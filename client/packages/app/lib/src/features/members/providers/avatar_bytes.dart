// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fetches and caches one user's avatar bytes.
///
/// Keyed by (userId, avatarUpdatedAt) rather than userId alone: an upload
/// changes the timestamp, which mints a new family key and triggers a fresh
/// fetch with no manual cache invalidation required. In-memory only and
/// `autoDispose` in memory so a long member list evicts what nobody is looking
/// at, with a size-capped disk copy so an eviction or a restart refetches nothing.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/media_disk_caches.dart';
import '../../../providers/providers.dart';

/// [updatedAt] is the profile's `avatar_updated_at`; callers do not ask for a
/// user whose is null.
typedef AvatarKey = ({String userId, int? updatedAt});

/// Null both while there is genuinely no avatar (a 404) and, transiently,
/// while the fetch is in flight; callers fall back to initials either way.
/// Sized past a member pane and a transcript's worth of authors, so an
/// ordinary switch between two channels evicts nothing.
final _recent = KeepAliveCache(128);

final avatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, AvatarKey>((ref, key) async {
      // Held past the last watcher, or a channel switch refetches every face.
      _recent.hold(ref, key);
      final cache = ref.watch(avatarCacheProvider);
      final diskKey = serverScopedKey(
        ref.watch(serverUrlProvider),
        '${key.userId}-${key.updatedAt}',
      );
      final cached = await cache.read(diskKey);
      if (cached != null) return cached;
      try {
        final fetched = await ref.watch(apiProvider).fetchAvatar(key.userId);
        unawaited(cache.write(diskKey, fetched.bytes));
        return fetched.bytes;
      } on NotFoundException catch (error, stack) {
        AppLog.swallowed(LogTag.media, 'This user has no avatar', error, stack);
        return null;
      }
    });
