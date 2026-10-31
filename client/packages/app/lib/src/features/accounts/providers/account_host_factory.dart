// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Builds the app's [AccountHost] and the shared services every account's container reads.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../../../desktop/desktop_window_shell.dart';
import '../../../diagnostics/debug_log.dart';
import '../../../diagnostics/debug_log_persistence.dart';
import '../../../providers/media_disk_caches.dart';
import '../../../providers/providers.dart';
import '../../../providers/startup_restores.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../emoji/providers/emoji_image_cache.dart';
import '../../messages/providers/attachment_preview_bytes.dart';
import 'account_host.dart';
import 'account_providers.dart';
import 'account_restore.dart';
import 'account_services.dart';
import 'account_slot.dart';
import 'account_store.dart';

/// One shared key store and emoji cache, then a container per account built on them.
///
/// See emojiImageCacheProvider's own doc for why the cache is opted into here rather than left as its default.
AccountHost createAccountHost(DesktopWindowShell shell) {
  final keyStore = createPersistentKeyStore();
  final emojiCache = createEmojiImageCache();
  final previewCache = createAttachmentPreviewCache();
  final avatarCache = createAvatarCache();
  final originalCache = createAttachmentOriginalCache();
  final accounts = AccountStore(keyStore);
  // One log for every account, since the error hooks are global.
  final debugLog = DebugLog(
    persistence: const PrefsDebugLogPersistence(),
    echo: kDebugMode,
  );
  late final AccountHost host;
  host = AccountHost(
    store: accounts,
    createContainer: (slot) => ProviderContainer(
      overrides: [
        debugLogProvider.overrideWith((ref) => debugLog),
        emojiImageCacheProvider.overrideWithValue(emojiCache),
        attachmentPreviewCacheProvider.overrideWithValue(previewCache),
        avatarCacheProvider.overrideWithValue(avatarCache),
        attachmentOriginalCacheProvider.overrideWithValue(originalCache),
        keyStoreProvider.overrideWithValue(keyStore),
        accountSlotProvider.overrideWithValue(slot),
        accountHostProvider.overrideWith((ref) => host),
        desktopWindowShellProvider.overrideWithValue(shell),
      ],
    ),
    startServices: (r) async {
      await restoreStartupPreferences(r.container);
      startAccountServices(r.container);
    },
    onActivate: (r) async {
      await resyncSharedPreferences(r.container);
      await resyncVoiceDevicePreferences(r.container);
    },
    readSession: (r) => restoreAccountSession(accounts, r),
    signOutRuntime: (r) => signOutVia(r.container.read),
  );
  return host;
}
