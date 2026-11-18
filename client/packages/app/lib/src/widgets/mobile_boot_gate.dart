// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When a phone's startup splash (`StartupApp`, the same one desktop shows) stays
/// up past bootstrap, so a cold launch never lands on an empty, disconnected
/// home while the session's first catch-up is still running.
///
/// `SlimMApp` reads this. The splash clears the moment the first catch-up lands
/// ([initialSyncCompleteProvider], which stays true for the rest of the
/// session) - so a later reconnect shows the rail's connection indicator,
/// never this. If that first attempt fails instead, the splash steps aside
/// for whatever the local store already holds and its offline indicator,
/// rather than trapping a phone with no signal on a splash that never
/// clears. [hasFailedSinceLiveProvider] is what tells a real failure from the
/// harmless `offline` the controller rests in for an instant before its
/// first connect - and, being a latch rather than a read of the current
/// status, it also keeps the splash from coming back on every retry that
/// follows: with the server unreachable, [SyncController] cycles
/// `connecting -> offline` on a growing backoff, and a plain
/// `status == offline` check would have flipped the splash on and off with
/// it (the bug this file used to have).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/startup_screen.dart';

/// Whether the boot splash should cover the home right now. Pure so its truth
/// table is tested directly, without a real mobile host or a live socket.
///
/// - Desktop is never held here: its splash ends with bootstrap.
/// - Once the first catch-up lands ([synced]) the home shows for good.
/// - Before that, the splash holds through the resting `offline` and the
///   first `connecting` attempt, and steps aside the moment
///   [hasFailedSinceLive] latches - once, for the rest of the session, so a
///   phone with no signal reaches its cached home and stays there rather
///   than flipping back to the splash on every retry.
bool shouldShowBootSplash({
  required bool isMobile,
  required bool synced,
  required bool hasFailedSinceLive,
}) {
  if (!isMobile || synced) return false;
  return !hasFailedSinceLive;
}

/// How long the boot splash waits on that first catch-up before asking.
const bootSplashPatience = Duration(seconds: 20);

/// What the splash asks once [bootSplashPatience] has passed. A browser can
/// reload; a second tab holding the local database is the usual cause there.
StartupPrompt stalledBootPrompt({
  required bool isWeb,
  required VoidCallback onRetry,
  required VoidCallback onOpenAnyway,
}) => StartupPrompt(
  title: 'Still connecting',
  detail: isWeb
      ? 'Close slim-m in other tabs, then reload.'
      : 'This is taking longer than usual.',
  primaryLabel: isWeb ? 'Reload' : 'Keep waiting',
  onPrimary: onRetry,
  secondaryLabel: 'Open anyway',
  onSecondary: onOpenAnyway,
);

/// Asks [stalledBootPrompt] once the splash has held for [bootSplashPatience].
class BootStallWatch {
  BootStallWatch({
    required this.prompt,
    required this.stillCovered,
    required this.openAnyway,
    required this.reload,
    this.isWeb = kIsWeb,
  });

  final StateController<StartupPrompt?> prompt;
  final bool Function() stillCovered;
  final VoidCallback openAnyway;
  final VoidCallback reload;
  final bool isWeb;
  Timer? _timer;

  void arm() {
    _timer?.cancel();
    _timer = Timer(bootSplashPatience, _ask);
  }

  void cancel() => _timer?.cancel();

  void _ask() {
    if (!stillCovered()) return;
    prompt.state = stalledBootPrompt(
      isWeb: isWeb,
      onRetry: () {
        prompt.state = null;
        isWeb ? reload() : arm();
      },
      onOpenAnyway: () {
        prompt.state = null;
        openAnyway();
      },
    );
  }
}
