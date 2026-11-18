// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one notice the board shows at a time: a failed call, a canvas error,
/// or ink still being retried, floated just above the dock whose tools and
/// call controls it is about.
///
/// Over the board and never in flow, so it moves nothing; one at a time, so
/// notices never stack and shove each other; and it fades in and out with its
/// condition instead of snapping (docs/design/desktop-vs-mobile.md, rule 6).
/// Hidden ink is said beside the zoom readout instead, by `CanvasZoomIndicator`.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/dock_reservation.dart';
import '../../../widgets/status_pill.dart';

class CanvasNotice extends ConsumerWidget {
  const CanvasNotice({
    super.key,
    required this.callError,
    required this.onRetryCall,
    required this.error,
    required this.onDismissError,
    required this.onRetryError,
    required this.unsavedInk,
  });

  final String? callError;
  final VoidCallback? onRetryCall;
  final String? error;
  final VoidCallback onDismissError;

  /// Set only for a failed load, which retries by itself and clears when one gets through.
  final VoidCallback? onRetryError;

  /// How many strokes are still being retried.
  final ValueListenable<int> unsavedInk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The dock's own bottom margin is outside what it reports.
    final lift =
        ref.watch(bottomDockReservationProvider) +
        AppSpacing.s12 +
        AppSpacing.s8;
    return Positioned(
      left: AppSpacing.s12,
      right: AppSpacing.s12,
      bottom: lift,
      child: Center(
        child: ValueListenableBuilder<int>(
          valueListenable: unsavedInk,
          builder: (context, unsaved, _) => AnimatedSwitcher(
            duration: AppMotion.reduced(context, AppMotion.base),
            switchInCurve: AppMotion.entrance,
            switchOutCurve: AppMotion.exit,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.bottomCenter,
              children: [...previous, ?current],
            ),
            child: _notice(unsaved) ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  /// The most urgent notice that applies: the call, then the canvas, then unsaved ink.
  Widget? _notice(int unsaved) {
    if (callError case final message?) {
      return StatusPill(
        key: const ValueKey('call'),
        severity: BannerSeverity.error,
        message: message,
        action: _action('Rejoin', onRetryCall),
      );
    }
    if (error case final message?) {
      final retrying = onRetryError != null;
      return StatusPill(
        key: ValueKey('error:$message'),
        severity: retrying ? BannerSeverity.warning : BannerSeverity.error,
        message: message,
        action: _action('Retry', onRetryError),
        onDismiss: retrying ? null : onDismissError,
      );
    }
    if (unsaved > 0) {
      return const StatusPill(
        key: ValueKey('ink'),
        severity: BannerSeverity.warning,
        message: 'Ink not saved yet. Retrying.',
      );
    }
    return null;
  }

  Widget? _action(String label, VoidCallback? onPressed) => onPressed == null
      ? null
      : AppButton(
          label: label,
          size: AppButtonSize.sm,
          variant: AppButtonVariant.soft,
          onPressed: onPressed,
        );
}
