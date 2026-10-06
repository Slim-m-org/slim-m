// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Discord-style startup screen: the brand lockup plus a status line,
/// shown in its own small window while `main.dart`'s async bootstrap
/// sequence runs, per decision 0012's superseding section.
///
/// A real, small OS window now, not a themed first frame inside the one
/// real window the way this screen first shipped - the owner reaffirmed the
/// ask decision 0012 originally rejected, with a use case that record never
/// weighed: this splash is meant to eventually host update-check/download
/// progress, which must exist before and outlive the main window's first
/// frame. See `DesktopWindowShell.applyInitialGeometry`, called ahead of
/// `runApp`, which is what actually puts the window into this small,
/// frameless, centred, fixed-size splash shape; this widget only draws what
/// sits inside it.
///
/// [status] is the room for that future update text: "Checking for
/// updates", "Downloading update", "Installing update" are the same one
/// line this already shows during ordinary bootstrap, just with different
/// words - see `main.dart`'s `startupStatusProvider` for where the current,
/// simple phase text comes from.
///
/// The mark alone, at the size `BootSplashScreen` uses for a phone, read as
/// an accidental placeholder rather than a designed screen once it sat in a
/// full desktop window rather than a phone's - the owner's own "looks
/// buggy" report. Pairing it with the wordmark `OnboardingShell`'s brand
/// rail already carries gives the same content the weight a splash needs to
/// read as deliberate, without inventing a new visual language for one
/// screen.
///
/// Always dark, regardless of the stored theme choice: that choice is
/// itself part of the async sequence this screen exists to mask, so there
/// is nothing else to render it in yet. Discord's own splash does the same.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'desktop_window_port.dart';
import 'startup_window_chrome.dart';
import 'update_package_view.dart' show packageManagerCommand;

/// The default [StartupScreen.status] text, and the only one every existing
/// test and every non-desktop launch ever sees: `main.dart` overrides it
/// with `startupStatusProvider`'s live value once bootstrap actually starts.
const defaultStartupStatus = 'Starting slim-m';

/// A newer version offered in the splash, and the two things the user can do
/// about it. Phase 1 of decision 0020: [onGet] opens the release rather than
/// self-applying, and [onDismiss] launches the current client unchanged.
/// A question the splash puts to the user, holding startup until it is
/// answered. Two buttons, because every one of these is a choice between
/// doing the thing now and going on without it: enable automatic updates or
/// not, restart into an installed update or not, open a release or not.
class StartupPrompt {
  const StartupPrompt({
    required this.title,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.onSecondary,
    this.detail,
  });

  final String title;

  /// One line under [title], typically what this install's own update
  /// mechanism is - see `startup_updates.dart`.
  final String? detail;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String secondaryLabel;
  final VoidCallback onSecondary;
}

/// How this install actually gets the update, in one line - because the app
/// cannot apply it the same way for every format (see decision 0020).
String updateActionHint(InstallFormat format) => switch (format) {
  InstallFormat.flatpak => 'Update with: flatpak update top.npcserver.slimm',
  InstallFormat.rpm =>
    'Update with your package manager: ${packageManagerCommand(format)}',
  InstallFormat.deb => 'Update with your package manager.',
  InstallFormat.appImage ||
  InstallFormat.tarball ||
  InstallFormat.apk ||
  InstallFormat.unknown => 'Open the release page to download the new version.',
};

class StartupApp extends StatelessWidget {
  const StartupApp({
    super.key,
    this.status = defaultStartupStatus,
    this.prompt,
    this.windowPort,
  });

  final String status;
  final StartupPrompt? prompt;

  /// Set where the native title bar is hidden; see [StartupWindowChrome].
  final DesktopWindowPort? windowPort;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'slim-m',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: StartupScreen(status: status, prompt: prompt, windowPort: windowPort),
  );
}

class StartupScreen extends StatelessWidget {
  const StartupScreen({
    super.key,
    this.status = defaultStartupStatus,
    this.prompt,
    this.windowPort,
  });

  final String status;
  final DesktopWindowPort? windowPort;

  /// When set, the splash shows a question instead of the plain status line,
  /// and waits on the user rather than proceeding on its own.
  final StartupPrompt? prompt;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.dark;
    final port = windowPort;
    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      body: Stack(
        children: [
          Center(
            child: AppFadeIn(
              offset: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppBrandMark(size: 64, color: tokens.accent),
                  const SizedBox(height: AppSpacing.s16),
                  Text(
                    'slim-m',
                    style: AppText.heading.copyWith(
                      color: tokens.textPrimary,
                      fontFamily: AppFonts.mono,
                      fontWeight: AppWeights.medium,
                      letterSpacing: 20 * AppTracking.mono,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s24),
                  if (prompt case final question?)
                    _Prompt(prompt: question, tokens: tokens)
                  else
                    Text(
                      status,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (port != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: StartupWindowChrome(port: port),
            ),
        ],
      ),
    );
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({required this.prompt, required this.tokens});

  final StartupPrompt prompt;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            prompt.title,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
          if (prompt.detail case final detail?) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.s16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppButton(
                label: prompt.secondaryLabel,
                variant: AppButtonVariant.ghost,
                onPressed: prompt.onSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              AppButton(
                label: prompt.primaryLabel,
                variant: AppButtonVariant.primary,
                onPressed: prompt.onPrimary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
