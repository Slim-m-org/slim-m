// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slim-m client.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show BrowserContextMenu, SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' show TokenPair, installWindowsRootFetching;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart'
    show GuardedConnectivity, MirrorSelfViewScope, applyCallMediaRole;

export 'src/desktop/startup_state.dart';

import 'src/api_failure.dart' show loadFailureRetries;
import 'src/default_server.dart';
import 'src/audio/sound_backend_warmup.dart';
import 'src/features/settings/providers/resolved_theme.dart';
import 'src/features/settings/providers/stored_theme.dart';
import 'src/features/settings/providers/theme_store.dart';
import 'src/deep_links.dart';
import 'src/features/share/providers/share_intake.dart';
import 'src/features/accounts/providers/account_host_factory.dart';
import 'src/features/accounts/widgets/account_call_pill.dart';
import 'src/features/accounts/widgets/account_root.dart';
import 'src/features/accounts/providers/account_providers.dart';
import 'src/features/accounts/providers/account_restore.dart';
import 'src/features/accounts/providers/account_services.dart';
import 'src/providers/active_account_mount.dart';
import 'src/providers/app_badge_sync.dart';
import 'src/providers/notification_read_sync.dart';
import 'src/widgets/enter_activates_buttons.dart';
import 'src/widgets/system_bars.dart';
import 'src/desktop/self_update/self_update_controller.dart';
import 'src/desktop/startup_updates.dart';
import 'src/providers/app_lock_controller.dart';
import 'src/desktop/close_behavior.dart';
import 'src/desktop/desktop_chrome.dart';
import 'src/desktop/desktop_quit_shortcut.dart';
import 'src/desktop/desktop_window_port.dart'
    show WindowManagerDesktopWindowPort;
import 'src/desktop/desktop_window_shell.dart';
import 'src/desktop/popout/popout_windowing.dart' show claimNativeMainWindow;
import 'src/desktop/providers/desktop_splash_preference.dart';
import 'src/desktop/splash_floor.dart';
import 'src/desktop/startup_screen.dart';
import 'src/desktop/startup_state.dart';
import 'src/diagnostics/debug_log.dart';
import 'src/storage/register_preferences_store_web.dart'
    if (dart.library.io) 'src/storage/register_preferences_store_io.dart';
import 'src/diagnostics/voice_harness.dart';
import 'src/features/settings/providers/autostart_setting.dart';
import 'src/features/settings/providers/display_density.dart';
import 'src/features/settings/providers/display_preferences.dart';
import 'src/push/providers/notification_tap_router.dart';
import 'src/providers/phone_landscape.dart';
import 'src/providers/providers.dart';
import 'src/providers/sync_controller.dart'
    show hasFailedSinceLiveProvider, initialSyncCompleteProvider;
import 'src/widgets/launch_cover.dart';
import 'src/widgets/mobile_boot_gate.dart';
import 'src/providers/startup_restores.dart';
import 'src/push/android_push_init.dart';
import 'src/routing/router.dart';
import 'src/semantics_tap_once_per_frame.dart';
import 'src/web_update/web_page.dart' show reloadPage;
import 'src/web_update/web_update_pill.dart';
import 'src/widgets/app_lock_gate.dart';
import 'src/widgets/ui_scale_frame.dart';
import 'src/features/auth/widgets/client_too_old_gate.dart';
import 'src/features/auth/widgets/server_identity_change_gate.dart';
import 'src/features/voice/providers/voice_settings_controller.dart';
import 'src/features/voice/widgets/call_audio_prompt.dart';
import 'src/features/voice/widgets/second_clock.dart';
import 'src/features/voice/widgets/incoming_call_overlay.dart';
import 'src/features/voice/widgets/picture_in_picture_gate.dart';
import 'src/features/voice/widgets/popout_host.dart';
import 'src/features/members/widgets/moderation_error_host.dart';
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
Future<void> main([List<String> args = const []]) async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // First: on Windows no plugin is registered until the main window exists.
  final mainWindow = await claimNativeMainWindow();
  SemanticsTapOncePerFrame.install(binding.platformDispatcher, binding);
  if (isAndroidHost) unawaited(drawUnderSystemBars());
  // Before the first SharedPreferences read, which countLaunch makes.
  registerPreferencesStore();
  // Before any audio stack opens: libpulse reads the role once per context.
  applyCallMediaRole();
  // livekit_client awaits this probe on every join; see the class doc.
  GuardedConnectivity.install();
  // Before the first connection, so every client is built through it.
  installWindowsRootFetching();
  // First, so a launch that dies in any later step still counts toward a rollback.
  await countLaunch();
  // The browser's own menu otherwise lands on top of every in-app one.
  if (kIsWeb) unawaited(BrowserContextMenu.disableContextMenu());
  // Registers media_kit's player backend; every inline video attachment goes through it (attachment_video_player.dart).
  MediaKit.ensureInitialized();
  await initAndroidPush();
  final shell = DesktopWindowShell();
  shell.nativeWindow = mainWindow;
  if (shell.port case final WindowManagerDesktopWindowPort port) {
    mainWindow?.onCloseRequested = port.onNativeCloseRequested;
  }
  await shell.applyInitialGeometry();
  shell.registerSecondInstanceHandler();
  DesktopQuitShortcut(shell).register();

  final host = createAccountHost(shell, await resolveOfficialServer());
  final container = host.createFirst();
  // Before anything that can throw, so startup failures land in the log too.
  installDiagnostics(container);
  // The window's state is one for the process, so the clock follows whichever account is on screen.
  SecondClock.instance.follow(container);
  host.addListener(() => SecondClock.instance.follow(host.active?.container));

  container.read(appReadyProvider.notifier).state = false;
  unawaited(
    _bootstrapApp(
      container,
      shell,
      launchedAtLogin: args.contains(autostartArgument),
    ),
  );

  runApp(AccountRoot(host: host, app: const SlimMApp()));
  final harnessTarget = kVoiceHarness ? harnessChannel(args) : null;
  if (harnessTarget != null) {
    unawaited(
      joinHarnessChannel(
        () => host.active!.container,
        harnessTarget,
        volumeFile: harnessVolumeFile(args),
        args: args,
      ),
    );
  }

  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await shell.lockSplashChrome();
  // Off the UI thread now, so a join cue never pays GStreamer's first init on it.
  unawaited(warmSoundBackend());
  // Only closing the last pop-out removes its KWin rule, so a crash with one open leaves it behind.
  unawaited(kwinClearLeftoverAboveFullScreen());
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
Future<void> _bootstrapApp(
  ProviderContainer container,
  DesktopWindowShell shell, {
  required bool launchedAtLogin,
}) async {
  var floor = Duration.zero;
  // Guarded: a step that throws must not leave the splash up for good, the handoff below always runs.
  await runStartupStep(container, 'startup', () async {
    floor = await _resolveSplashFloor(container);
    await awaitBootstrapWithSplashFloor(
      () => _runBootstrapSequence(container, shell),
      floor: floor,
    );
    // After the session restore: having an account decides whether the splash asks about updates at all.
    await runStartupUpdates(container);
  });
  await shell.prepareHandoff(
    container,
    splashFloor: floor,
    fadeOut: AppMotion.base,
  );
  // Revealed before the flip: a window reports its real size only once shown, and the real UI must not build at the splash's 380px.
  await shell.revealAfterHandoff();
  container.read(appReadyProvider.notifier).state = true;
  // A login launch goes where a close would, the tray or the taskbar, instead of covering what the user opened first.
  if (launchedAtLogin) unawaited(shell.requestClose());
  unawaited(container.read(selfUpdateProvider).confirmStart());
  unawaited(repairAutostart(container));
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
Future<Duration> _resolveSplashFloor(ProviderContainer container) =>
    restoreSplashFloor(
      container,
      (c) => splashFloorFor(c.read(splashDurationControllerProvider)),
    );

Future<void> _runBootstrapSequence(
  ProviderContainer container,
  DesktopWindowShell shell,
) async {
  container.read(startupStatusProvider.notifier).state = 'Restoring session';
  if (!await wipeKeychainOnFreshInstall(container)) {
    await container.read(accountHostProvider)!.start();
  }

  container.read(startupStatusProvider.notifier).state = 'Loading preferences';
  // Independent restores off one cached SharedPreferences future: concurrent rather than an event-loop turn apiece, paid on every launch.
  await restoreStartupPreferences(container);
  // After the session and app-lock preference both restore, so the first frame past the splash never shows the real app unlocked.
  container.read(appLockControllerProvider.notifier).armOnLaunch();

  container.read(startupStatusProvider.notifier).state = 'Connecting';
  startAccountServices(container);
  ActiveAccountMount.start(container.read(accountHostProvider), container, [
    appBadgeSyncProvider,
    notificationReadSyncProvider,
  ]);
  DeepLinkListener.start(container, forwarded: shell.forwardedLinks);
  ShareIntake.start(container);
  await shell.registerListenersAndTray(container);
}

/// Linux and Windows hide the native title bar for the splash; macOS keeps it.
bool get _splashIsFrameless =>
    currentDesktopPlatform() == DesktopPlatform.linux ||
    currentDesktopPlatform() == DesktopPlatform.windows;

/// The root. Which surface is shown follows the session, enforced by the
/// router's redirect: a revoked session lands on sign-in from wherever the user
/// was, without any screen checking for itself. How it looks follows the
/// stored appearance choice, which is restored before the first frame.
class SlimMApp extends ConsumerStatefulWidget {
  const SlimMApp({super.key, this.isDesktopOverride});

  /// Lets a widget test take the phone branch; `flutter test` on Linux is a desktop host.
  final bool? isDesktopOverride;

  @override
  ConsumerState<SlimMApp> createState() => _SlimMAppState();
}

class _SlimMAppState extends ConsumerState<SlimMApp> {
  /// Only a cold launch is covered: swapping the app for the splash later would drop the call overlay, dialogs and router stack.
  bool _coldLaunchCover = true;

  bool get _onDesktop => widget.isDesktopOverride ?? isDesktopHost;

  void _spendCover() {
    _stall.cancel();
    if (_coldLaunchCover) setState(() => _coldLaunchCover = false);
  }

  late final BootStallWatch _stall;

  void _askIfStalled() {
    if (!_onDesktop && _coldLaunchCover) _stall.arm();
  }

  @override
  void initState() {
    super.initState();
    _stall = BootStallWatch(
      prompt: ref.read(startupPromptProvider.notifier),
      stillCovered: () => mounted && _coldLaunchCover,
      openAnyway: _spendCover,
      reload: reloadPage,
      anotherTabIsOpen: ref.read(crossTabProvider).anotherTabIsOpen,
    );
    if (ref.read(appReadyProvider) && !ref.read(sessionProvider).isSignedIn) {
      _coldLaunchCover = false;
    }
    if (ref.read(appReadyProvider)) _askIfStalled();
    ref.listenManual(appReadyProvider, (_, ready) {
      if (ready && !ref.read(sessionProvider).isSignedIn) _spendCover();
      if (ready) _askIfStalled();
    });
    ref.listenManual(initialSyncCompleteProvider, (_, synced) {
      if (synced) _spendCover();
    });
    ref.listenManual(hasFailedSinceLiveProvider, (_, failed) {
      if (failed) _spendCover();
    });
    _signOuts = ref.read(sessionProvider).changes.listen((tokens) {
      if (tokens == null) _spendCover();
    });
  }

  StreamSubscription<TokenPair?>? _signOuts;

  @override
  void dispose() {
    _stall.cancel();
    unawaited(_signOuts?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A phone keeps the one splash up past bootstrap, through the first catch-up, so nothing second follows it.
    final phoneCovered =
        _coldLaunchCover &&
        !_onDesktop &&
        ref.watch(sessionProvider).isSignedIn &&
        shouldShowBootSplash(
          isMobile: true,
          synced: ref.watch(initialSyncCompleteProvider),
          hasFailedSinceLive: ref.watch(hasFailedSinceLiveProvider),
        );
    final theme = _theme();
    final splash = StartupApp(
      status: ref.watch(startupStatusProvider),
      prompt: ref.watch(startupPromptProvider),
      leaving: ref.watch(startupLeavingProvider),
      rounded: currentDesktopPlatform() == DesktopPlatform.linux,
      themeMode: theme.mode,
      lightTokens: theme.light,
      darkTokens: theme.dark,
      windowPort: _splashIsFrameless
          ? ref.read(desktopWindowShellProvider).port
          : null,
    );
    final ready = ref.watch(appReadyProvider);
    if (_onDesktop) return ready ? _app() : splash;
    // One splash element from launch to fade, so its own animation never restarts at the handoff.
    return LaunchCover(
      covered: !ready || phoneCovered,
      cover: splash,
      child: ready ? _app() : const SizedBox.shrink(),
    );
  }

  ResolvedTheme _theme() {
    final theme = resolveTheme(
      ref.watch(themeControllerProvider),
      custom: ref.watch(customThemeProvider),
      spaceDefault: ref.watch(spaceDefaultThemeProvider),
    );
    if (!ref.watch(highContrastControllerProvider)) return theme;
    return ResolvedTheme(
      applyHighContrast(theme.light),
      applyHighContrast(theme.dark),
      theme.mode,
    );
  }

  Widget _app() {
    final theme = _theme();
    ref.watch(spaceThemeSyncProvider);

    // Watched rather than read: this is what mounts the tap listener, and a
    // notification tap has to reach the router from outside the widget tree.
    ref.watch(notificationTapRouterProvider);

    return MaterialApp.router(
      title: 'slim-m',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light, theme.light),
      darkTheme: buildTheme(Brightness.dark, theme.dark),
      // Without this line MaterialApp's own ThemeMode.system default applies,
      // and no choice the user makes can reach the theme; that is what shipped.
      themeMode: theme.mode,
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
    final lockedPhone = ref.watch(portraitLockedPhoneProvider);
    final scale = uiScaleFactor(ref.watch(uiScaleControllerProvider));
    final mirrored = MirrorSelfViewScope(
      mirror: ref.watch(
        voiceSettingsControllerProvider.select((s) => s.mirrorSelfView),
      ),
      child: PopOutHost(
        child: DesktopChrome(
          child: MediaQuery(
            data: scaleMediaQuery(
              keepPortraitShell(
                overrideMotion(MediaQuery.of(context), motionChoice),
                lockedPhone: lockedPhone,
              ),
              scale,
            ),
            // Above the routed tree, its dialogs, toasts and the call overlay: a locked screen covers all of them and takes them out of focus and semantics.
            child: UiScaleFrame(
              scale: scale,
              child: AppLockGate(
                child: Stack(
                  children: [
                    // Outside everything routed: a client the server refuses has nothing useful behind this. Fail-open.
                    ThemeBackdrop(
                      child: ModerationErrorHost(
                        child: ClientTooOldGate(
                          child: ServerIdentityChangeGate(
                            child: PictureInPictureGate(child: densityWrapped),
                          ),
                        ),
                      ),
                    ),
                    const Positioned.fill(child: ToastOverlay()),
                    const Positioned.fill(child: WebUpdatePill()),
                    const Positioned.fill(child: AccountCallPill()),
                    const Positioned.fill(child: IncomingCallOverlay()),
                    const Positioned.fill(child: CallAudioPrompt()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsFor(Theme.of(context).brightness),
      child: EnterActivatesButtons(
        child: AppLoadRetryPolicy(retries: loadFailureRetries, child: mirrored),
      ),
    );
  },
);
