// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one notice the board shows at a time: a canvas error, ink still being
/// retried, or a failed call, floated just above the dock whose tools and
/// call controls it is about.
///
/// Over the board and never in flow, so it moves nothing; one at a time, so
/// notices never stack and shove each other; and it fades in and out with its
/// condition instead of snapping (docs/design/errors-and-status.md, rule 3).
/// Hidden ink is said beside the zoom readout instead, by `CanvasZoomIndicator`.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/dock_reservation.dart';
import '../../../widgets/status_pill.dart';
import 'canvas_forbidden_message.dart';

class CanvasNotice extends ConsumerStatefulWidget {
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

  /// Null when the call cannot be retried, which gives its notice a close button instead.
  final VoidCallback? onRetryCall;
  final String? error;
  final VoidCallback onDismissError;

  /// Set only for a failed load, which retries by itself and clears when one gets through.
  final VoidCallback? onRetryError;

  /// How many strokes are still being retried.
  final ValueListenable<int> unsavedInk;

  @override
  ConsumerState<CanvasNotice> createState() => _CanvasNoticeState();
}

class _CanvasNoticeState extends ConsumerState<CanvasNotice> {
  /// The call failure closed here; a failure that clears and comes back shows again.
  String? _closedCallError;

  @override
  void didUpdateWidget(CanvasNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.callError == null) _closedCallError = null;
  }

  @override
  Widget build(BuildContext context) {
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
          valueListenable: widget.unsavedInk,
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

  /// The most urgent notice that applies. The board's own state comes before
  /// the call: a stopped pen or a failed load, then ink still saving, then a
  /// failure the user can dismiss, and only then the call, which can be closed.
  Widget? _notice(int unsaved) {
    final error = widget.error;
    final holdsBoard =
        error != null &&
        (widget.onRetryError != null || canvasErrorBlocksDrawing(error));
    if (holdsBoard) return _errorPill(error);
    if (unsaved > 0) {
      return const StatusPill(
        key: ValueKey('ink'),
        severity: BannerSeverity.warning,
        message: 'Ink not saved yet. Retrying.',
      );
    }
    if (error != null) return _errorPill(error);
    if (widget.callError case final message? when message != _closedCallError) {
      final retry = widget.onRetryCall;
      return StatusPill(
        key: const ValueKey('call'),
        severity: BannerSeverity.error,
        message: message,
        action: _action('Rejoin', retry),
        onDismiss: retry != null
            ? null
            : () => setState(() => _closedCallError = message),
      );
    }
    return null;
  }

  Widget _errorPill(String message) {
    final retrying = widget.onRetryError != null;
    return StatusPill(
      key: ValueKey('error:$message'),
      severity: retrying ? BannerSeverity.warning : BannerSeverity.error,
      message: message,
      action: _action('Retry', widget.onRetryError),
      onDismiss: retrying ? null : widget.onDismissError,
    );
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
