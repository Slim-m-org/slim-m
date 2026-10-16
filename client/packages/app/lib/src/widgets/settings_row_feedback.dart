// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a settings row reports after it writes: the saved flash and the
/// persistent error, inset to the card's own 16.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'success_flash.dart';

class SettingsRowFeedback extends StatelessWidget {
  const SettingsRowFeedback({
    super.key,
    required this.tick,
    this.error,
    this.onDismiss,
  });

  final int tick;
  final String? error;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
          child: SuccessFlash(tick: tick),
        ),
        if (error case final message?)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(message: message, onDismiss: onDismiss),
          ),
      ],
    );
  }
}
