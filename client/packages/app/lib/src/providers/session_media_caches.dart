// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Forgets every on-disk image an account's server supplied, when its session ends.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/emoji/providers/emoji_catalog_provider.dart';
import '../features/messages/providers/attachment_preview_bytes.dart';
import 'media_disk_caches.dart';
import 'providers.dart';

/// Drops the avatar, preview, original and emoji files cached for the server [read] is bound to.
Future<void> clearSessionMediaCaches(
  T Function<T>(ProviderListenable<T> provider) read,
) async {
  final server = read(serverUrlProvider);
  await clearAttachmentPreviews(read(attachmentPreviewCacheProvider), server);
  await clearMediaDiskCaches(
    server,
    avatars: read(avatarCacheProvider),
    originals: read(attachmentOriginalCacheProvider),
  );
  await read(
    emojiImageCacheProvider,
  ).removeWithPrefix(serverScopedKey(server, ''));
}
