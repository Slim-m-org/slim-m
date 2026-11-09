// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The end of a full page: more items may follow, and only asking finds out.
/// Shared by the open-reports queue and the history feed beside it
/// (`reports_screen.dart`, `report_history_pane.dart`), which page the same
/// way. Split into its own file so neither imports the other just for this.
///
/// Carries the failure of the last attempt too, as the sentence its controller
/// wrote, inline and next to its retry, rather than letting it replace the pages
/// already on screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ReportsLoadMoreRow extends StatelessWidget {
  const ReportsLoadMoreRow({
    super.key,
    required this.loading,
    required this.error,
    required this.onTap,
  });

  final bool loading;
  final String? error;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.s8),
          child: AppSpinner(size: AppSpinnerSize.lg),
        ),
      );
    }
    if (error case final message?) {
      return AppErrorState(message: message, onRetry: () => unawaited(onTap()));
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s8),
        child: AppButton(
          label: 'Load more',
          variant: AppButtonVariant.secondary,
          onPressed: () => unawaited(onTap()),
        ),
      ),
    );
  }
}
