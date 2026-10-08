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

import '../../providers/dock_reservation.dart';

/// At phone width the dock's cards reach into this corner, so the readout
/// rides above them by the dock's measured height instead of sitting under it.
class CanvasZoomIndicator extends ConsumerWidget {
  const CanvasZoomIndicator({
    super.key,
    required this.document,
    required this.tokens,
    required this.onFit,
  });

  /// Fits the camera to what is drawn; a view-only change, so always enabled.
  final VoidCallback onFit;

  final CanvasDocument document;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Align(
    alignment: Alignment.bottomLeft,
    child: Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.sizeOf(context).width < kCompactWidth
            ? ref.watch(bottomDockReservationProvider) + AppSpacing.s12
            : 0,
      ),
      child: _readout(),
    ),
  );

  Widget _readout() => SafeArea(
    minimum: const EdgeInsets.all(AppSpacing.s12),
    child: ListenableBuilder(
      listenable: document,
      builder: (context, _) {
        final percent = (document.camera.zoom * 100).round();
        // Its own node: merged into the surface's, it made the whole canvas a button that swallowed every drag on web.
        return Semantics(
          container: true,
          button: true,
          label: 'Fit view, zoom $percent percent',
          excludeSemantics: true,
          onTap: onFit,
          child: Tooltip(
            message: 'Fit view',
            child: Material(
              color: tokens.surfaceRaised,
              shape: StadiumBorder(
                side: BorderSide(color: tokens.borderSubtle),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onFit,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: AppSizes.icon28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s8,
                    ),
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
          ),
        );
      },
    ),
  );
}
