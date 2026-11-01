// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one on-screen readout of how zoomed in the canvas currently is, and
/// the way back to the content: tapping it fits the view.
///
/// The canvas is a bounded large world, not literally infinite (see
/// `CLAUDE.md`), and panning or pinching around it left nothing on screen
/// saying how far zoomed in or out a person had gone - the owner's backlog
/// named this directly as a gap. This closes it with the smallest thing that
/// answers the question, a small pill in the top-left corner, which the
/// presence roster (top-right) and the floating dock (bottom-center) leave free.
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

import 'canvas_outside_board_notice.dart';
import 'canvas_people_cluster.dart';
import 'canvas_people_panel.dart';
import 'canvas_people_session.dart';
import 'canvas_view_mode_controls.dart';

/// The canvas's top-left cluster: who is here, the view pill and the zoom readout, clear of the bottom dock at any width.
class CanvasZoomIndicator extends StatelessWidget {
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
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.topLeft, child: _readout());

  Widget _readout() => SafeArea(
    minimum: const EdgeInsets.all(AppSpacing.s12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Consumer(
          builder: (context, ref, _) {
            final session = CanvasPeopleScope.maybeOf(context);
            final people = canvasPeople(
              call: ref.watch(canvasCallPeopleProvider),
              onCanvas: session?.onCanvas ?? const [],
            ).any((p) => !p.isSelf);
            if (!people && viewMode == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: Wrap(
                spacing: AppSpacing.s8,
                runSpacing: AppSpacing.s8,
                children: [
                  if (people) const CanvasPeopleCluster(),
                  if (viewMode case final mode?)
                    CanvasViewModeControls(mode: mode, tokens: tokens),
                ],
              ),
            );
          },
        ),
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
      // 100% is the shared area fitted, whatever the screen.
      final fit = document.sharedFitZoom;
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
