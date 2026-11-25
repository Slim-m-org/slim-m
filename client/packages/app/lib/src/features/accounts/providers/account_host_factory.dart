// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Builds the app's [AccountHost] and the shared services every account's container reads.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog;
import 'package:slimm_platform/platform.dart';

import '../../../audio/call_start_yields.dart';
import '../../../default_server.dart';
import '../../../desktop/desktop_window_shell.dart';
import '../../../diagnostics/debug_log.dart';
import '../../../diagnostics/debug_log_persistence.dart';
import '../../../diagnostics/debug_log_router.dart';
import '../../../providers/app_lock_controller.dart';
import '../../../providers/media_disk_caches.dart';
import '../../../providers/providers.dart';
import '../../../providers/startup_restores.dart';
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../emoji/providers/emoji_image_cache.dart';
import '../../messages/providers/attachment_preview_bytes.dart';
import '../../../push/providers/notification_tap_router.dart';
import '../../../push/providers/push_channel_providers.dart';
import '../../video/providers/native_video_host.dart';
import '../../video/providers/video_host_capability.dart';
import '../../voice/providers/shortcut_overrides.dart';
import 'account_host.dart';
import 'account_providers.dart';
import 'account_restore.dart';
import 'account_services.dart';
import 'account_slot.dart';
import 'process_app_lock.dart';
import 'account_store.dart';

/// Runs [body] so every record it logs belongs to the account [container] serves.
T scopedToAccount<T>(ProviderContainer container, T Function() body) =>
    AppLog.scoped(
      () => container.read(accountSlotProvider)?.account?.origin,
      body,
    );

/// One shared key store and emoji cache, then a container per account built on them.
///
/// See emojiImageCacheProvider's own doc for why the cache is opted into here rather than left as its default.
AccountHost createAccountHost(DesktopWindowShell shell, Uri official) {
  final keyStore = createPersistentKeyStore();
  final emojiCache = createEmojiImageCache();
  final previewCache = createAttachmentPreviewCache();
  final avatarCache = createAvatarCache();
  final originalCache = createAttachmentOriginalCache();
  final accounts = AccountStore(keyStore);
  late final AccountHost host;
  // The error hooks are global, so one router hands each record to its own account's log.
  final debugLogs = DebugLogRouter(
    onScreenOrigin: () => host.active?.account?.origin,
  );
  // One for every account, so a call joined in any of them makes the others' sounds give way.
  final callStartYields = CallStartYields();
  // The keybinds switch is per device, so a server not on screen drops its system-wide grabs too.
  final callKeybinds = CallKeybindsStore(optIn: isDesktopHost);
  // One per tab: each claims the tab's id, and a second claim in one tab reads as a duplicated tab.
  final crossTab = CrossTab();
  // The native callbacks and handlers are process-wide, so they cannot belong to a container that gets disposed.
  final apnsToken = ApnsTokenChannel();
  final notificationTaps = NotificationTapChannel();
  // One lock for every container, or a link or switch into an account not yet opened would skip it.
  late final appLock = createProcessAppLock(host);
  // The runner has one native player, so every account's player shares one host to take turns on it.
  final videoHost = NativeVideoHost();
  final notifications = LocalNotifications(
    onActivated: (payload) => openNotificationTarget(shell, host, payload),
  );
  host = AccountHost(
    store: accounts,
    createContainer: (slot) => ProviderContainer(
      overrides: [
        debugLogSinkProvider.overrideWithValue(debugLogs),
        debugLogProvider.overrideWith((ref) {
          final log = DebugLog(
            persistence: PrefsDebugLogPersistence(
              origin: () => slot.account?.origin,
            ),
            origin: () => slot.account?.origin,
            echo: kDebugMode && debugLogs.isEmpty,
          );
          debugLogs.add(log);
          ref.onDispose(() => debugLogs.remove(log));
          return log;
        }),
        emojiImageCacheProvider.overrideWithValue(emojiCache),
        attachmentPreviewCacheProvider.overrideWithValue(previewCache),
        avatarCacheProvider.overrideWithValue(avatarCache),
        attachmentOriginalCacheProvider.overrideWithValue(originalCache),
        keyStoreProvider.overrideWithValue(keyStore),
        accountSlotProvider.overrideWithValue(slot),
        accountHostProvider.overrideWith((ref) => host),
        callStartYieldsProvider.overrideWithValue(callStartYields),
        callKeybindsStoreProvider.overrideWithValue(callKeybinds),
        appLockControllerProvider.overrideWith((ref) => appLock),
        crossTabProvider.overrideWithValue(crossTab),
        officialServerProvider.overrideWithValue(official),
        desktopWindowShellProvider.overrideWithValue(shell),
        nativeVideoHostProvider.overrideWithValue(videoHost),
        apnsTokenChannelProvider.overrideWithValue(apnsToken),
        notificationTapChannelProvider.overrideWithValue(notificationTaps),
        localNotificationsProvider.overrideWithValue(notifications),
      ],
    ),
    startServices: (r) => AppLog.scoped(() => r.account?.origin, () async {
      await restoreStartupPreferences(r.container);
      startAccountServices(r.container);
    }),
    onActivate: (r) async {
      await resyncSharedPreferences(r.container);
      await resyncVoiceDevicePreferences(r.container);
    },
    readSession: (r) => restoreAccountSession(accounts, r),
    signOutRuntime: (r) => AppLog.scoped(
      () => r.account?.origin,
      () => signOutVia(r.container.read),
    ),
  );
  return host;
}
