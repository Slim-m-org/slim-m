// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' show installWindowsRootFetching;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart'
    show GuardedConnectivity, applyCallMediaRole;

import '../push/android_push_init.dart';
import '../semantics_tap_once_per_frame.dart';
import '../storage/register_preferences_store_web.dart'
    if (dart.library.io) '../storage/register_preferences_store_io.dart';
import '../widgets/system_bars.dart';
import 'desktop_quit_shortcut.dart';
import 'self_update/self_update_controller.dart' show countLaunch;
import 'desktop_window_port.dart' show WindowManagerDesktopWindowPort;
import 'desktop_window_shell.dart';
import 'popout/popout_windowing.dart' show claimNativeMainWindow;

/// Claims the native main window, brings up the platform services that must precede the first account, and returns the window shell.
Future<DesktopWindowShell> startPlatform(WidgetsBinding binding) async {
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
  return shell;
}
