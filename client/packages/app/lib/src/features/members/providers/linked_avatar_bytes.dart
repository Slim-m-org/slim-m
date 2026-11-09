// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One member's linked-account picture, copied by the server at link time.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/providers.dart';
import 'profile_media_fetch.dart';

/// [updatedAt] is the link's `avatar_updated_at`: relinking changes it and
/// so mints a fresh fetch, the same cache key scheme as `avatarBytesProvider`.
typedef LinkedAvatarKey = ({String userId, int updatedAt});

final _recent = KeepAliveCache(32);

/// Null while loading and when the server has no picture after all.
final linkedAvatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, LinkedAvatarKey>((ref, key) async {
      _recent.hold(ref, key);
      final api = ref.watch(apiProvider);
      return fetchProfileMedia(
        ref,
        () => api.fetchLinkedDiscordAvatar(key.userId),
        cache: _recent,
        key: key,
        noneMessage: 'No linked picture',
      );
    });
