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
    this.onDismissError,
    this.inCard = false,
  });

  /// `GuardedActionState.successTick`.
  final int tick;
  final String? error;
  final VoidCallback? onDismissError;

  /// Inside a settings card as one of its rows, so it takes the card's 16 inset.
  final bool inCard;

  @override
  Widget build(BuildContext context) {
    final inset = inCard ? AppSpacing.s16 : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: SuccessFlash(tick: tick),
        ),
        if (error case final message?)
          Padding(
            padding: inCard
                ? const EdgeInsets.all(AppSpacing.s16)
                : const EdgeInsets.only(top: AppSpacing.s8),
            child: AppErrorState(message: message, onDismiss: onDismissError),
          ),
      ],
    );
  }
}
