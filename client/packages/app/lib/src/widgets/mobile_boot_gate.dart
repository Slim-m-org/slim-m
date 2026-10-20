// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Covers the very first server connection on a phone with a boot splash, so a
/// cold launch never lands on an empty, disconnected home while the session's
/// first catch-up is still running.
///
/// Desktop is left untouched: it already shows its own pre-`runApp` startup
/// screen (decision 0012) and its window is sized before the first frame, so
/// this gate returns the child unchanged on a desktop host.
///
/// The splash clears the moment the first catch-up lands
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;

import '../providers/sync_controller.dart';

/// Whether the boot splash should cover the home right now. Pure so its truth
/// table is tested directly, without a real mobile host or a live socket.
///
/// - Desktop is never gated: it has its own startup screen.
/// - Once the first catch-up lands ([synced]) the home shows for good.
/// - Before that, the splash holds through the resting `offline` and the
///   first `connecting` attempt, and steps aside the moment
///   [hasFailedSinceLive] latches - once, for the rest of the session, so a
///   phone with no signal reaches its cached home and stays there rather
///   than flipping back to the splash on every retry.
@visibleForTesting
bool shouldShowBootSplash({
  required bool isMobile,
  required bool synced,
  required bool hasFailedSinceLive,
}) {
  if (!isMobile || synced) return false;
  return !hasFailedSinceLive;
}

class MobileBootGate extends ConsumerWidget {
  const MobileBootGate({
    super.key,
    required this.child,
    this.isDesktopOverride,
  });

  final Widget child;

  /// Overrides [isDesktopHost] purely so a widget test can drive the mobile
  /// branch without a real phone host: `flutter test` on Linux reports
  /// desktop true for every build, which otherwise leaves this whole gate
  /// dead code under test - see `mobile_boot_gate_test.dart`.
  final bool? isDesktopOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isDesktopOverride ?? isDesktopHost) return child;

    final synced = ref.watch(initialSyncCompleteProvider);
    final hasFailedSinceLive = ref.watch(hasFailedSinceLiveProvider);
    final showSplash = shouldShowBootSplash(
      isMobile: true,
      synced: synced,
      hasFailedSinceLive: hasFailedSinceLive,
    );
    return showSplash ? const BootSplashScreen() : child;
  }
}

/// The phone's boot splash: the brand mark on the themed ground, with a quiet
/// spinner beneath so a slow first connect reads as working rather than stuck.
class BootSplashScreen extends StatelessWidget {
  const BootSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppFadeIn(
              offset: 0,
              child: AppBrandMark(size: 56, color: tokens.accent),
            ),
            const SizedBox(height: AppSpacing.s32),
            AppSpinner(color: tokens.textSecondary),
          ],
        ),
      ),
    );
  }
}
