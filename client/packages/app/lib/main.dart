// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slim-m client.
library;

import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

export 'src/desktop/startup_state.dart';

import 'src/deep_links.dart';
import 'src/desktop/self_update/self_update_controller.dart';
import 'src/desktop/startup_updates.dart';
import 'src/providers/app_lock_controller.dart';
import 'src/providers/app_lock_preference.dart';
import 'src/providers/desktop_call_notifier.dart';
import 'src/providers/desktop_message_notifier.dart';
import 'src/providers/viewing_reporter.dart';
import 'src/desktop/close_behavior.dart';
import 'src/desktop/desktop_chrome.dart';
import 'src/desktop/desktop_quit_shortcut.dart';
import 'src/desktop/desktop_window_shell.dart';
import 'src/providers/attachment_preview_quality.dart';
import 'src/providers/desktop_splash_preference.dart';
import 'src/providers/emoji_catalog_provider.dart';
import 'src/providers/emoji_image_cache.dart';
import 'src/providers/media_preferences.dart';
import 'src/providers/message_page_size.dart';
import 'src/providers/image_cache_preference.dart';
import 'src/desktop/splash_floor.dart';
import 'src/desktop/startup_screen.dart';
import 'src/desktop/startup_state.dart';
import 'src/diagnostics/debug_log.dart';
import 'src/providers/display_preferences.dart';
import 'src/providers/notification_tap_router.dart';
import 'src/providers/providers.dart';
import 'src/providers/push_controller.dart';
import 'src/providers/sync_controller.dart';
import 'src/providers/voice_controller.dart';
import 'src/push/android_push_messages.dart';
import 'src/routing/router.dart';
import 'src/web_update/web_update_pill.dart';
import 'src/widgets/app_lock_gate.dart';
import 'src/widgets/client_too_old_gate.dart';
import 'src/widgets/server_identity_change_gate.dart';
import 'src/widgets/incoming_call_overlay.dart';
import 'src/widgets/picture_in_picture_gate.dart';
import 'src/widgets/popout_host.dart';
import 'src/widgets/moderation_error_host.dart';
import 'src/widgets/toast_overlay.dart';

/// Entry point.
///
/// [DesktopWindowShell.applyInitialGeometry] runs before [runApp] on purpose:
/// it is the one step that has to land before the very first Flutter frame
/// paints, or the startup screen below would flash at the OS default size
/// before visibly shrinking to the small splash shape - a no-op on every
/// platform but a real desktop build. [DesktopWindowShell.registerSecondInstanceHandler]
/// runs right after it for the same reason: a launcher click racing this
/// process's own startup has to find a listener already in place.
/// [DesktopQuitShortcut.register] joins them here rather than waiting for
/// [_bootstrapApp]'s own tray setup, since it needs no [ProviderContainer]
/// and a quit combo pressed in the first instant the window is up should
/// already work.
///
/// Everything else that used to run here now runs inside [_bootstrapApp],
/// off the critical path to the first frame: [SlimMApp] shows [StartupApp]
/// while [appReadyProvider] is false and swaps to the real app once that
/// future resolves, so [restoreSession] still finishes before the router
/// ever builds - the same "no sign-in-then-jump" guarantee this file always
/// carried, just realised by a watched provider instead of an await ahead
/// of [runApp].
///
/// [DesktopWindowShell.lockSplashChrome] runs after [runApp], once the first
/// frame is confirmed rasterized, rather than alongside [applyInitialGeometry]
/// above. An Xvfb+fluxbox reproduction of this exact sequence showed why:
/// disabling resize and hiding the Linux title bar before the window had
/// ever been shown raced the still-pending splash resize and won, so the
/// window mapped at the native 1280x720 default instead of the small splash
/// size. Waiting for the real first frame avoids that race entirely.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // First, so a launch that dies in any later step still counts toward a rollback.
  await countLaunch();
  // The browser's own menu otherwise lands on top of every in-app one.
  if (kIsWeb) unawaited(BrowserContextMenu.disableContextMenu());
  // Registers media_kit's player backend; every inline video attachment goes through it (attachment_video_player.dart).
  MediaKit.ensureInitialized();
  await _initAndroidPush();
  await DesktopWindowShell.applyInitialGeometry();
  DesktopWindowShell.registerSecondInstanceHandler();
  DesktopQuitShortcut.register(DesktopWindowShell.port);

  // See emojiImageCacheProvider's own doc for why this is opted into here rather than left as its default.
  final container = ProviderContainer(
    overrides: [
      emojiImageCacheProvider.overrideWithValue(createEmojiImageCache()),
    ],
  );
  // Before anything that can throw, so startup failures land in the log too.
  installDiagnostics(container);

  container.read(appReadyProvider.notifier).state = false;
  unawaited(_bootstrapApp(container));

  runApp(
    UncontrolledProviderScope(container: container, child: const SlimMApp()),
  );

  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await DesktopWindowShell.lockSplashChrome();
}

/// The async sequence [StartupApp] masks: session restore (so the router's
/// first redirect already knows the answer instead of showing sign-in and
/// jumping to channels a frame later), the preference-controller
/// restores, sync/push bring-up, and the desktop window shell's own
/// listener/tray registration - a no-op on every platform but a real
/// desktop build. The sync and push controllers are read here rather than
/// left to whichever screen wants them first: they react to session changes
/// for their whole lives, and a restored session never passes through the
/// sign-in screen that would otherwise have touched them.
///
/// Wrapped in [awaitBootstrapWithSplashFloor] rather than flipping
/// [appReadyProvider] the instant this resolves: on desktop that sequence
/// can finish in a frame or two on a warm start, which is the exact reason
/// the startup screen went unnoticed - see `src/desktop/splash_floor.dart`.
/// [_resolveSplashFloor] picks which floor to wait out - or none at all,
/// with the splash turned off - ahead of that wrapped call, so the choice is
/// already known before the floor starts counting.
///
/// [DesktopWindowShell.prepareHandoff] and [DesktopWindowShell.revealAfterHandoff]
/// bracket the ready flip rather than running before or after it: the window
/// has to already be hidden and resized to its real geometry before the real
/// UI swaps in, and has to stay hidden until that swapped-in UI has actually
/// painted, or the handoff would show a stale splash frame, an empty one, or
/// the real content briefly stretched across the splash's small bounds. See
/// decision 0012's superseding section for why this hide/resize/show
/// sequence is the traded-off stand-in for a genuine second window - and why
/// a disabled splash still goes through it: the window is born small by the
/// native runner before any preference can be read, so even "off" cannot
/// skip that first small frame, only the added dwell on top of it.
Future<void> _bootstrapApp(ProviderContainer container) async {
  final floor = await _resolveSplashFloor(container);
  await awaitBootstrapWithSplashFloor(
    () => _runBootstrapSequence(container),
    floor: floor,
  );
  // After the session restore: having an account decides whether the splash asks about updates at all.
  await runStartupUpdates(container);
  await DesktopWindowShell.prepareHandoff(container);
  // Revealed before the flip: a window reports its real size only once shown, and the real UI must not build at the splash's 380px.
  await DesktopWindowShell.revealAfterHandoff();
  container.read(appReadyProvider.notifier).state = true;
  unawaited(container.read(selfUpdateProvider).confirmStart());
}

/// Restores the splash on/off and duration preferences and turns them into
/// the one [Duration] [awaitBootstrapWithSplashFloor] needs, ahead of the
/// rest of bootstrap rather than alongside it in [_runBootstrapSequence]'s
/// own preference-restore block - that ordering is what lets "off" mean no
/// floor at all rather than one only known partway through the sequence it
/// bounds. The on/off-to-duration mapping itself is [splashFloorFor], a pure
/// function this only restores state for and calls - see its own doc.
///
/// Both controllers restore from [preferencesProvider]'s own cached future,
/// the same one every other preference in [_runBootstrapSequence] reads, so
/// this cannot race or duplicate that restore. Each controller's own
/// constructor default (splash on, standard duration) is what a read before
/// this restore completes would see, which already matches the fallback this
/// function needs: nothing here has to special-case "not loaded yet".
Future<Duration> _resolveSplashFloor(ProviderContainer container) async {
  await container.read(splashDurationControllerProvider.notifier).restore();
  return splashFloorFor(container.read(splashDurationControllerProvider));
}

Future<void> _runBootstrapSequence(ProviderContainer container) async {
  container.read(startupStatusProvider.notifier).state = 'Restoring session';
  await restoreSession(container);

  container.read(startupStatusProvider.notifier).state = 'Loading preferences';
  // Independent restores off one cached SharedPreferences future: concurrent rather than an event-loop turn apiece, paid on every launch.
  final voice = container.read(voiceControllerProvider.notifier);
  await Future.wait([
    container.read(themeControllerProvider.notifier).restore(),
    container.read(timeFormatControllerProvider.notifier).restore(),
    container.read(motionPreferenceControllerProvider.notifier).restore(),
    container.read(highContrastControllerProvider.notifier).restore(),
    container.read(imageCacheLimitControllerProvider.notifier).restore(),
    container
        .read(attachmentPreviewQualityControllerProvider.notifier)
        .restore(),
    container.read(mediaAutoDownloadControllerProvider.notifier).restore(),
    container.read(gifAutoplayControllerProvider.notifier).restore(),
    container.read(messagePageSizeControllerProvider.notifier).restore(),
    container.read(appLockPreferenceProvider.notifier).restore(),
    voice.restoreCameraPreference(),
    voice.restoreVoiceActivitySensitivity(),
    voice.restorePushToTalkPreference(),
    voice.restoreAudioDevicePreferences(),
  ]);
  // After the session and app-lock preference both restore, so the first frame past the splash never shows the real app unlocked.
  container.read(appLockControllerProvider.notifier).armOnLaunch();

  container.read(startupStatusProvider.notifier).state = 'Connecting';
  container.read(syncControllerProvider);
  container.read(pushControllerProvider);
  container.read(deepLinkControllerProvider);
  container.read(desktopMessageNotifierProvider);
  container.read(viewingReporterProvider);
  container.read(desktopCallNotifierProvider);
  await DesktopWindowShell.registerListenersAndTray(container);
}

/// Wires Firebase and the FCM background message handler Android needs to
/// ever show a notification while backgrounded or killed - the relay sends
/// data-only messages, so nothing appears unless this app builds it (see
/// `src/push/android_push_messages.dart`). Deliberately does not also listen
/// for foreground messages: see that file's doc for why a foreground push
/// never needs to show anything of its own.
///
/// Must run before [runApp], and the background handler must be registered
/// here specifically rather than from a provider or a widget: FCM invokes it
/// in its own isolate with no widget tree and no [ProviderContainer], so it
/// has to already be a reachable top-level function before that isolate can
/// exist. A no-op on iOS, Linux and the web, and best-effort even on Android:
/// a contributor's build with no `google-services.json` (see
/// `android/app/build.gradle.kts`) throws here, and push, like on iOS, must
/// never be the reason the rest of the app fails to start.
///
/// Swallowing that throw loses nothing, because the same missing credentials or
/// absent Play Services also degrade push registration through
/// `FcmTokenChannel`, and showing notifications cannot work without a token to
/// register in the first place.
Future<void> _initAndroidPush() async {
  if (!isAndroidHost) return;
  try {
    await ensureFirebaseInitialized();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (_) {
    // No Firebase credentials or no Play Services: push degrades either way.
  }
}

/// The root. Which surface is shown follows the session, enforced by the
/// router's redirect: a revoked session lands on sign-in from wherever the user
/// was, without any screen checking for itself. How it looks follows the
/// stored appearance choice, which is restored before the first frame.
class SlimMApp extends ConsumerWidget {
  const SlimMApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(appReadyProvider)) {
      return StartupApp(
        status: ref.watch(startupStatusProvider),
        prompt: ref.watch(startupPromptProvider),
        windowPort: currentDesktopPlatform() == DesktopPlatform.linux
            ? DesktopWindowShell.port
            : null,
      );
    }

    final choice = ref.watch(themeControllerProvider);
    final highContrast = ref.watch(highContrastControllerProvider);
    final lightTokens = highContrast
        ? applyHighContrast(AppTokens.light)
        : AppTokens.light;
    final darkTokens = highContrast
        ? applyHighContrast(_darkTokensFor(choice))
        : _darkTokensFor(choice);

    // Watched rather than read: this is what mounts the tap listener, and a
    // notification tap has to reach the router from outside the widget tree.
    ref.watch(notificationTapRouterProvider);

    return MaterialApp.router(
      title: 'slim-m',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, lightTokens),
      darkTheme: buildTheme(Brightness.dark, darkTokens),
      // Without this line MaterialApp's own ThemeMode.system default applies,
      // and no choice the user makes can reach the theme; that is what shipped.
      themeMode: _themeModeFor(choice),
      // Theme switching is on the motion spec's never-animates list, and
      // Material lerps it over 200ms by default.
      themeAnimationDuration: Duration.zero,
      routerConfig: ref.watch(routerProvider),
      // Material's own list rows are sized for a thumb whatever the window,
      // which is what made the settings and administration screens read as a
      // phone blown up. Applied here rather than per screen so a new one
      // cannot forget, and read from the window so nothing has to say which.
      builder: appChromeBuilder,
    );
  }
}

/// The one wrapper every top-level `MaterialApp` in this app must apply.
///
/// Pulled out of [SlimMApp.build] so the UI snapshot test harness can import
/// and reuse this exact function rather than rebuilding its own copy: a copy
/// is what previously let the harness render every desktop settings and
/// admin screen at touch density, silently, because it had drifted from what
/// this file actually wraps the router in.
///
/// This is also where [MotionPreferenceController]'s choice reaches
/// [AppMotion.isReduced]: a [Consumer] wrapping the whole routed tree in a
/// [MediaQuery] carrying [overrideMotion]'s answer, rather than a change to
/// [AppMotion] itself, which stays a pure read of whatever `MediaQuery` it is
/// given - the same choke point every animated widget already asks.
///
/// [DesktopChrome] is the outermost layer: the frameless title bar and the
/// first-run tray notice, both no-ops unless [DesktopWindowShell.active] -
/// never true in a plain `flutter test` run, which is what keeps this from
/// changing the tree shape of every other test in this package.
Widget appChromeBuilder(BuildContext context, Widget? child) => Consumer(
  builder: (context, ref, _) {
    final densityWrapped = ListTileTheme.merge(
      dense: !AppTouchTargets.of(context),
      child: child ?? const SizedBox.shrink(),
    );
    final motionChoice = ref.watch(motionPreferenceControllerProvider);
    return PopOutHost(
      child: DesktopChrome(
        child: MediaQuery(
          data: overrideMotion(MediaQuery.of(context), motionChoice),
          // Above the routed tree, its dialogs, toasts and the call overlay: a locked screen covers all of them and takes them out of focus and semantics.
          child: AppLockGate(
            child: Stack(
              children: [
                // Outside everything routed: a client the server refuses has nothing useful behind this. Fail-open.
                ModerationErrorHost(
                  child: ClientTooOldGate(
                    child: ServerIdentityChangeGate(
                      child: PictureInPictureGate(child: densityWrapped),
                    ),
                  ),
                ),
                const Positioned.fill(child: ToastOverlay()),
                const Positioned.fill(child: WebUpdatePill()),
                const Positioned.fill(child: IncomingCallOverlay()),
              ],
            ),
          ),
        ),
      ),
    );
  },
);

ThemeMode _themeModeFor(AppThemeChoice choice) => switch (choice) {
  AppThemeChoice.system => ThemeMode.system,
  AppThemeChoice.light => ThemeMode.light,
  AppThemeChoice.dark || AppThemeChoice.trueBlack => ThemeMode.dark,
};

/// True black is a third palette rather than a fourth mode: it is the dark
/// theme built from a different token set, so it needs no second dark slot
/// that MaterialApp does not have.
AppTokens _darkTokensFor(AppThemeChoice choice) =>
    choice == AppThemeChoice.trueBlack ? AppTokens.trueBlack : AppTokens.dark;
