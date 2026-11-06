// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first-time notice itself: shown once, the first time the window
/// reopens after closing hid or minimised it rather than quitting.
/// An info [StatusBanner]: it clears itself after a few seconds, and either way
/// the notice is marked shown so it is not repeated.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../widgets/status_banner.dart';
import 'close_behavior.dart';
import 'first_run_tray_notice.dart';

class FirstRunTrayNoticeBanner extends ConsumerWidget {
  const FirstRunTrayNoticeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(firstRunTrayNoticeCloseActionProvider);
    if (action == null) return const SizedBox.shrink();

    return StatusBanner(
      message: _copyFor(action),
      margin: const EdgeInsets.all(AppSpacing.s8),
      onDismiss: () => unawaited(_dismiss(ref, action)),
    );
  }

  /// [CloseAction.hideToTray] is reachable only through the tray icon, so
  /// that is what it names; [CloseAction.minimizeToTaskbar] has no tray to
  /// point at, so it says the one thing that is true there instead - the
  /// window kept its taskbar and Alt-Tab entry.
  String _copyFor(CloseAction action) => switch (action) {
    CloseAction.hideToTray =>
      'slim-m is still running in the tray. Use the tray icon to reopen '
          'or quit it, or turn off Close to tray in Settings.',
    CloseAction.minimizeToTaskbar =>
      'slim-m is minimised, not closed. Reopen it from the taskbar '
          'or Alt-Tab.',
  };

  Future<void> _dismiss(WidgetRef ref, CloseAction action) async {
    ref.read(firstRunTrayNoticeCloseActionProvider.notifier).state = null;
    final notice = await ref.read(firstRunTrayNoticeProvider.future);
    await notice.markShown(action);
  }
}
