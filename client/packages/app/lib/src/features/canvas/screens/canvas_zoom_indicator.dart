// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one on-screen readout of how zoomed in the canvas currently is, and
/// the way back to the content: tapping it fits the view.
///
/// The canvas is a bounded large world, not literally infinite (see
/// `CLAUDE.md`), and panning or pinching around it left nothing on screen
/// saying how far zoomed in or out a person had gone - the owner's backlog
/// named this directly as a gap. This closes it with the smallest thing that
/// answers the question, a small pill in the one corner nothing else already
/// claims: `canvas_presence_roster.dart`'s own doc maps the error/truncation
/// banners to top-left-to-center and the floating dock to bottom-center,
/// which leaves bottom-left free.
///
/// Deliberately not a minimap, and not a position readout either: a
/// position needs [CanvasDocument.contentBounds], which that getter's own
/// doc says is a plain scan meant for one Recenter tap, never once a frame -
/// exactly the cost a camera-driven rebuild here would pay on every pan and
/// pinch. Zoom alone costs nothing extra: [CanvasDocument.camera] is already
/// read every frame elsewhere, and answers most of what "where am I" means
/// for a roughly dozen-person canvas, where the existing Recenter action is
/// already the way back if a person really is lost.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../widgets/canvas_pill_surface.dart';

import '../../modules/providers/dock_reservation.dart';
import 'canvas_outside_board_notice.dart';
import 'canvas_view_mode_controls.dart';

/// At phone width the dock's cards reach into this corner, so the readout
/// rides above them by the dock's measured height instead of sitting under it.
/// Wider, it lifts only when its own row would reach the centred dock.
class CanvasZoomIndicator extends ConsumerWidget {
  const CanvasZoomIndicator({
    super.key,
    required this.document,
    required this.tokens,
    required this.onFit,
    this.viewMode,
    required this.onBringIn,
  });

  /// Moves objects the board cannot hold back onto it.
  final VoidCallback onBringIn;

  /// Fits the camera to what is drawn; a view-only change, so always enabled.
  final VoidCallback onFit;

  final CanvasDocument document;
  final AppTokens tokens;

  /// Switches between the shared board and this viewer's own arrangement.
  final CanvasViewMode? viewMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = MediaQuery.sizeOf(context).width < kCompactWidth;
    return CustomSingleChildLayout(
      delegate: _CornerDelegate(
        lift: ref.watch(bottomDockReservationProvider) + AppSpacing.s12,
        dockWidth: ref.watch(bottomDockWidthProvider),
        alwaysLifted: phone,
      ),
      child: _readout(),
    );
  }

  Widget _readout() => SafeArea(
    minimum: const EdgeInsets.all(AppSpacing.s12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (viewMode case final mode?) ...[
          CanvasViewModeControls(mode: mode, tokens: tokens),
          const SizedBox(height: AppSpacing.s8),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _zoomPill(),
            Flexible(
              child: CanvasOutsideBoardNotice(
                document: document,
                tokens: tokens,
                onBringIn: onBringIn,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _zoomPill() => ListenableBuilder(
    listenable: document,
    builder: (context, _) {
      // 100% is the whole board fitted, whatever the screen.
      final board = document.board;
      final fit = board == null ? 1.0 : boardFitZoom(board, document.viewport);
      final percent = (document.camera.zoom / fit * 100).round();
      // Its own node: merged into the surface's, it made the whole canvas a button that swallowed every drag on web.
      return Semantics(
        container: true,
        button: true,
        label: 'Fit view, zoom $percent percent',
        excludeSemantics: true,
        onTap: onFit,
        child: Tooltip(
          message: 'Fit view',
          child: CanvasPillSurface(
            tokens: tokens,
            onTap: onFit,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppSizes.icon28),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$percent%',
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                        fontWeight: AppWeights.medium,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s4),
                    Icon(
                      AppIcons.recenter,
                      size: AppSizes.icon16,
                      color: tokens.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Pins the readout bottom-left, lifted over the dock when it could reach the corner.
///
/// A layout delegate rather than a LayoutBuilder: the readout listens to the
/// document, and mounting it during layout kept a frame callback alive under
/// reduce motion.
class _CornerDelegate extends SingleChildLayoutDelegate {
  const _CornerDelegate({
    required this.lift,
    required this.dockWidth,
    required this.alwaysLifted,
  });

  final double lift;
  final double dockWidth;
  final bool alwaysLifted;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final dockLeft = (size.width - dockWidth) / 2;
    final reachesDock = dockWidth > 0 && childSize.width > dockLeft;
    final lifted = alwaysLifted || reachesDock;
    return Offset(0, size.height - childSize.height - (lifted ? lift : 0));
  }

  @override
  bool shouldRelayout(_CornerDelegate old) =>
      old.lift != lift ||
      old.dockWidth != dockWidth ||
      old.alwaysLifted != alwaysLifted;
}
