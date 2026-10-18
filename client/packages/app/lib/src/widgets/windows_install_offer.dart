// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > About on a Windows copy that runs from an extracted folder: it
/// never updates itself, so this says so and offers the one move that fixes it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../desktop/self_update/self_update_failure.dart';
import '../providers/windows_adopt.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

class WindowsInstallOffer extends ConsumerStatefulWidget {
  const WindowsInstallOffer({super.key});

  @override
  ConsumerState<WindowsInstallOffer> createState() =>
      _WindowsInstallOfferState();
}

class _WindowsInstallOfferState extends ConsumerState<WindowsInstallOffer> {
  bool _installing = false;
  SelfUpdateFailure? _failure;

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _failure = null;
    });
    try {
      await ref.read(windowsAdoptActionProvider)();
    } on SelfUpdateFailure catch (failure, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'set state failed, ignored',
        failure,
        stack,
      );
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(windowsAdoptAvailableProvider)) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final failure = _failure;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s16),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.s20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AppSpacing.s12,
          children: [
            Text(
              'Automatic updates are off',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            Text(
              'This copy runs from a folder. Install it for your account '
              'to keep it up to date.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            if (failure != null)
              AppErrorState(message: failure.message, detail: failure.detail),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: _installing
                    ? 'Installing…'
                    : 'Install for automatic updates',
                onPressed: _installing ? null : () => unawaited(_install()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
