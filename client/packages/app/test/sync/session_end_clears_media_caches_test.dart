// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whichever way a session ends, the account's cached images go with it.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/providers/media_disk_caches.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../support/memory_byte_cache.dart';
import '../support/sync_harness.dart';
import '../support/sync_live_rig.dart';

void main() {
  test('a session the server ended clears every image cache', () async {
    final previews = MemoryByteCache();
    final avatars = MemoryByteCache();
    final originals = MemoryByteCache();
    final emoji = MemoryByteCache();
    final rig = await SyncLiveRig.build(
      (router) => router.on(
        'POST',
        '/sync',
        (_) => jsonResponse({'scopes': <Object>[]}),
      ),
      seeded: const [],
      overrides: [
        attachmentPreviewCacheProvider.overrideWithValue(previews),
        avatarCacheProvider.overrideWithValue(avatars),
        attachmentOriginalCacheProvider.overrideWithValue(originals),
        emojiImageCacheProvider.overrideWithValue(emoji),
      ],
    );
    final server = rig.container.read(serverUrlProvider);
    final other = Uri.parse('https://other.example');
    for (final cache in [previews, avatars, originals, emoji]) {
      cache.entries[serverScopedKey(server, 'x')] = Uint8List(1);
      cache.entries[serverScopedKey(other, 'x')] = Uint8List(1);
    }
    rig.signIn();
    await rig.waitFor(() => rig.status.name == 'live');

    rig.container.read(sessionProvider).clear();

    await rig.waitFor(
      () => [previews, avatars, originals, emoji].every(
        (c) => c.entries.keys.every((k) => k == serverScopedKey(other, 'x')),
      ),
      reason: 'the ended session left its cached images on disk',
    );
    for (final cache in [previews, avatars, originals, emoji]) {
      expect(cache.entries.keys, [serverScopedKey(other, 'x')]);
    }
  });
}
