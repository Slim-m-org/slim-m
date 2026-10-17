// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The startup window, after the "Startup Window" design: a dot lattice
/// ripples out, four of its points assemble into the mark, the wordmark
/// settles under it, and the real bootstrap phases tick off as a mono
/// checklist over a hairline progress rule. Shown in its own small window
/// while `main.dart`'s async bootstrap sequence runs, per decision 0012's
/// superseding section; `DesktopEntrance` carries the mark on into the main
/// window.
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
/// [status] feeds the checklist: each new value marks the previous phase
/// done, update phases included ("Checking for updates", "Installing ...");
/// see `main.dart`'s `startupStatusProvider`.
///
/// Always dark, regardless of the stored theme choice: that choice is
/// itself part of the async sequence this screen exists to mask, so there
/// is nothing else to render it in yet. Discord's own splash does the same.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'desktop_window_port.dart';
import 'startup_lattice.dart';
import 'startup_steps.dart';
import 'startup_window_chrome.dart';
import 'update_package_view.dart' show packageManagerCommand;

/// The default [StartupScreen.status] text, and the only one every existing
/// test and every non-desktop launch ever sees: `main.dart` overrides it
/// with `startupStatusProvider`'s live value once bootstrap actually starts.
const defaultStartupStatus = 'Starting slim-m';

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
  InstallFormat.testFlight => 'Update in the TestFlight app.',
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
    this.leaving = false,
  });

  final String status;
  final StartupPrompt? prompt;

  /// See `startupLeavingProvider`.
  final bool leaving;

  /// Set where the native title bar is hidden; see [StartupWindowChrome].
  final DesktopWindowPort? windowPort;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'slim-m',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: StartupScreen(
      status: status,
      prompt: prompt,
      windowPort: windowPort,
      leaving: leaving,
    ),
  );
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({
    super.key,
    this.status = defaultStartupStatus,
    this.prompt,
    this.windowPort,
    this.leaving = false,
  });

  final String status;
  final DesktopWindowPort? windowPort;

  /// Fades the content out ahead of the handoff; see `startupLeavingProvider`.
  final bool leaving;

  /// When set, the splash shows a question instead of the checklist, and
  /// waits on the user rather than proceeding on its own.
  final StartupPrompt? prompt;

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  double _seconds = 0;
  final List<String> _steps = [];
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _record(widget.status);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.isReduced(context);
    if (_reduced) {
      _ticker.stop();
      _seconds = kStartupSettledAt;
    } else if (!_ticker.isActive && _seconds < kStartupSettledAt) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(StartupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != oldWidget.status) _record(widget.status);
  }

  void _record(String status) {
    // The placeholder before bootstrap reports anything is not a phase of its own.
    if (status == defaultStartupStatus || _steps.lastOrNull == status) return;
    _steps.add(status);
  }

  void _tick(Duration elapsed) {
    setState(() => _seconds = elapsed.inMicroseconds / 1e6);
    if (widget.leaving && _seconds >= kStartupSettledAt) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Widget _lockup(AppTokens tokens, double word) => Stack(
    children: [
      Positioned.fill(
        child: CustomPaint(
          painter: StartupLatticePainter(
            seconds: _seconds,
            dot: tokens.borderStrong,
            accent: tokens.accent,
          ),
        ),
      ),
      Positioned(
        top: 194 + 6 * (1 - word),
        left: 0,
        right: 0,
        child: Opacity(
          opacity: word,
          child: Text(
            'slim-m',
            textAlign: TextAlign.center,
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.medium,
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    const tokens = AppTokens.dark;
    final port = widget.windowPort;
    final prompt = widget.prompt;
    final word = _reduced
        ? 1.0
        : AppMotion.entrance.transform(
            ((_seconds - kStartupWordAt) / 0.25).clamp(0.0, 1.0),
          );
    return Scaffold(
      backgroundColor: tokens.surfaceRaised,
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: widget.leaving ? 0 : 1,
              duration: AppMotion.reduced(context, AppMotion.base),
              curve: AppMotion.exit,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox.fromSize(
                    size: kStartupCanvas,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AnimatedSlide(
                            // A question needs the lower half of the window, so the lockup rises to make room.
                            offset: Offset(0, prompt == null ? 0 : -0.2),
                            duration: AppMotion.reduced(
                              context,
                              AppMotion.base,
                            ),
                            curve: AppMotion.entrance,
                            child: _lockup(tokens, word),
                          ),
                        ),
                        if (prompt == null)
                          Positioned(
                            left: 140,
                            top: 236,
                            width: 200,
                            child: StartupSteps(
                              steps: _steps,
                              finished: widget.leaving,
                              spin: _reduced ? 0 : _seconds * 1.5,
                              tokens: tokens,
                            ),
                          )
                        else
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 168,
                            child: Center(
                              child: _Prompt(prompt: prompt, tokens: tokens),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (prompt == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: StartupProgressRule(
                progress: startupProgress(
                  _steps.length,
                  finished: widget.leaving,
                ),
                tokens: tokens,
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
