// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A GIF favorite's thumbnail, streamed through this deployment's server.
///
/// In memory for the session only, like the search-result thumbnails it sits
/// beside; an attachment favorite draws from the attachment preview cache.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/cache_for.dart';
import '../../../providers/providers.dart';

final _recent = KeepAliveCache(48);

final favoritePreviewBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, id) async {
      _recent.hold(ref, id);
      final fetched = await ref.watch(apiProvider).fetchFavoritePreview(id);
      return fetched.bytes;
    });
