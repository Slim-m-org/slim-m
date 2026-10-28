// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notices laid over the top of the board: a failed call, a canvas error,
/// a capped region and ink still waiting to be saved. Over the board, not above
/// it, because a banner that took height re-fitted the board mid-draw.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_truncated_notice.dart';

class CanvasBanners extends StatelessWidget {
  const CanvasBanners({
    super.key,
    required this.callError,
    required this.onRetryCall,
    required this.error,
    required this.onDismissError,
    required this.onRetryError,
    required this.truncated,
    required this.unsavedInk,
  });

  final String? callError;
  final VoidCallback? onRetryCall;
  final String? error;
  final VoidCallback onDismissError;
  final VoidCallback? onRetryError;
  final bool truncated;

  /// How many strokes are still being retried.
  final ValueListenable<int> unsavedInk;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (callError != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s12),
            child: AppErrorState(message: callError!, onRetry: onRetryCall),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s12),
            child: AppErrorState(
              message: error!,
              onDismiss: onDismissError,
              onRetry: onRetryError,
            ),
          ),
        if (truncated) const CanvasTruncatedNotice(),
        ValueListenableBuilder<int>(
          valueListenable: unsavedInk,
          builder: (context, count, _) =>
              count == 0 ? const SizedBox.shrink() : const _UnsavedInkNotice(),
        ),
      ],
    ),
  );
}

class _UnsavedInkNotice extends StatelessWidget {
  const _UnsavedInkNotice();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(
      AppSpacing.s12,
      0,
      AppSpacing.s12,
      AppSpacing.s12,
    ),
    child: AppCallout(
      child: Text('Your latest ink is not saved yet. Retrying.'),
    ),
  );
}
