// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notices laid over the top of the board: a failed call, a canvas error,
/// a capped region and ink still waiting to be saved, as the same
/// [StatusBanner] the voice stage uses. Over the board, not above it, because
/// a banner that took height re-fitted the board mid-draw.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';

const _gap = EdgeInsets.only(top: AppSpacing.s12);

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
      children: [
        if (callError != null)
          StatusBanner(
            severity: BannerSeverity.error,
            sticky: true,
            message: callError!,
            margin: _gap,
            action: _retry(onRetryCall),
          ),
        if (error != null)
          StatusBanner(
            severity: BannerSeverity.error,
            message: error!,
            margin: _gap,
            onDismiss: onDismissError,
            action: _retry(onRetryError),
          ),
        if (truncated)
          const StatusBanner(
            severity: BannerSeverity.warning,
            sticky: true,
            message: 'Some ink in this region is not shown. Zoom in to see it.',
            margin: _gap,
          ),
        ValueListenableBuilder<int>(
          valueListenable: unsavedInk,
          builder: (context, count, _) => count == 0
              ? const SizedBox.shrink()
              : const StatusBanner(
                  severity: BannerSeverity.warning,
                  sticky: true,
                  message: 'Your latest ink is not saved yet. Retrying.',
                  margin: _gap,
                ),
        ),
      ],
    ),
  );

  Widget? _retry(VoidCallback? onRetry) => onRetry == null
      ? null
      : AppButton(
          label: 'Retry',
          size: AppButtonSize.sm,
          variant: AppButtonVariant.soft,
          onPressed: onRetry,
        );
}
