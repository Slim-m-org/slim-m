// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The ordered, failure-isolated steps of a deliberate quit and of a relaunch.
library;

import '../features/accounts/providers/account_host.dart';
import '../features/voice/providers/call_restore.dart';
import 'desktop_window_port.dart';
import 'quit_step.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Runs a quit one step at a time so one failure never keeps the window open.
class DesktopQuitFlow {
  DesktopQuitFlow({
    required this.beforeExit,
    required this.forceExit,
    required this.stepTimeout,
  });

  /// What must not outlive this process: the Linux share audio mix, which would pause the media players feeding it.
  final Future<void> Function() beforeExit;

  /// Ends the process when the window cannot be destroyed.
  final void Function() forceExit;

  /// A quit step that never answers is given up on, so the window can still close.
  final Duration stepTimeout;

  Future<void>? _quitting;

  /// Single-flight: a second trigger gets the quit already running.
  Future<void> quit(
    DesktopWindowPort port, {
    required Future<void> Function() flushGeometry,
    required AccountHost? Function() accounts,
  }) => _quitting ??= _quit(port, flushGeometry, accounts);

  /// Starts a fresh copy through [port] once a share's audio mix has ended.
  Future<void> relaunch(DesktopWindowPort port) async {
    await beforeExit();
    await port.relaunch();
  }

  Future<void> _quit(
    DesktopWindowPort port,
    Future<void> Function() flushGeometry,
    AccountHost? Function() accounts,
  ) async {
    await runQuitStep(
      'forget the call',
      stepTimeout,
      () => _forgetCall(accounts()),
    );
    await runQuitStep('end the share audio', stepTimeout, beforeExit);
    await runQuitStep('save the window position', stepTimeout, flushGeometry);
    try {
      await port.destroy();
    } catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not close the window on quit',
        error: error,
        stack: stack,
      );
      forceExit();
    }
  }

  /// A deliberate quit, so no call it leaves, in any Space, comes back on the next start.
  Future<void> _forgetCall(AccountHost? accounts) async {
    final containers = {
      for (final space in accounts?.accounts ?? const <AccountRuntime>[])
        space.container,
      ?accounts?.active?.container,
    };
    for (final container in containers) {
      try {
        final restore = await container.read(callRestoreProvider.future);
        await restore.markQuit();
      } catch (error, stack) {
        AppLog.warning(
          LogTag.platform,
          'Could not forget the call on quit',
          error: error,
          stack: stack,
        );
      }
    }
  }
}
