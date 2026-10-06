// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen `AppLockGate` shows over the whole app while locked.
///
/// Prompts the moment it mounts, and again on every tap of its own retry
/// affordance. There is no way to dismiss this except a successful
/// `AppLockController.unlock`: back is swallowed by the controller, and the
/// gate takes the app beneath out of focus and semantics, so this screen owns
/// the only focus scope and takes focus as it mounts.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/app_lock_controller.dart';

class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({super.key});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  /// Already true on the very first build, before [_attempt] itself has run:
  /// that call is scheduled for right after this build, so starting busy
  /// avoids one frame of an enabled "Unlock" button an already-in-flight
  /// prompt would ignore anyway.
  bool _busy = true;
  bool _failed = false;

  /// Scheduled a frame out rather than called directly: [_attempt] reaches
  /// its first `await` synchronously, and any `setState` before that point
  /// would run while this state is still inside its own [initState], which
  /// Flutter forbids.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_attempt()));
  }

  Future<void> _attempt() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final unlocked = await ref
        .read(appLockControllerProvider.notifier)
        .unlock();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !unlocked;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return FocusScope(
      autofocus: true,
      child: Scaffold(
        backgroundColor: tokens.surfaceBase,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    AppIcons.appLock,
                    size: AppSizes.icon32,
                    color: tokens.accent,
                  ),
                  const SizedBox(height: AppSpacing.s16),
                  Text(
                    'slim-m is locked',
                    textAlign: TextAlign.center,
                    style: AppText.heading.copyWith(color: tokens.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  Text(
                    'Confirm it is you to open your messages.',
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: tokens.textSecondary),
                  ),
                  if (_failed) ...[
                    const SizedBox(height: AppSpacing.s16),
                    AppErrorState(
                      message: "Couldn't confirm it was you.",
                      onRetry: _attempt,
                      retryLabel: 'Try again',
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s24),
                  AppButton(
                    label: 'Unlock',
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.lg,
                    full: true,
                    busy: _busy,
                    onPressed: _busy ? null : _attempt,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
