// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a settings write says back, under its card: the transient "Saved" and
/// a persistent error. Empty, it takes no height.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'success_flash.dart';

class SettingsSaveFeedback extends StatelessWidget {
  const SettingsSaveFeedback({
    super.key,
    required this.tick,
    required this.error,
    required this.onDismissError,
  });

  /// `GuardedActionState.successTick`.
  final int tick;
  final String? error;
  final VoidCallback onDismissError;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SuccessFlash(tick: tick),
      if (error != null) ...[
        const SizedBox(height: AppSpacing.s8),
        AppErrorState(message: error!, onDismiss: onDismissError),
      ],
    ],
  );
}
