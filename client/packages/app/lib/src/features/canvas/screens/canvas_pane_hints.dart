// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two overlay hints `canvas_pane_body.dart`'s drawing surface shows in
/// place of a blank canvas: a loading spinner while the viewport fetch is
/// still in flight, and an empty-canvas prompt once it has resolved to
/// nothing. Split out once the body crossed the 500-line hard ceiling; both
/// are self-contained `Positioned.fill` overlays with no state of their own.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_summary.dart';

/// The one thing this pane's own onboarding copy never said: how to move
/// around it at all. Width-branched per `docs/design/desktop-vs-mobile.md`
/// rule 1 (window width, never platform) - the same compact-width proxy
/// for a touch-first surface `CanvasEmptyHint`'s sibling widgets already
/// use throughout this package.
String panZoomHint(double width) => width < kCompactWidth
    ? 'Drag with two fingers to pan, pinch to zoom'
    : 'Scroll to pan, hold Ctrl and scroll to zoom, or drag with the '
          'middle mouse button';

/// The signature feature's first impression used to be a flat rectangle
/// with nothing on it while loading - pixel-identical, to a sighted user,
/// to a broken or blank canvas. `Semantics`' own `loading` label already
/// covered a screen reader; this is the sighted half of that guarantee.
///
/// A determinate, static ring under reduce motion rather than the usual
/// spinning one: unlike a platform activity indicator this project
/// deliberately leaves ticking (`AppMotion`'s own doc explains why), this
/// pane sits inside `HomeShell`'s wider swap-in, which itself has to
/// settle to nothing ticking under the setting - see
/// `home_shell_canvas_test.dart`'s own reduce-motion assertion.
class CanvasLoadingHint extends StatelessWidget {
  const CanvasLoadingHint({super.key, required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: Center(
          child: AppSpinner(
            size: AppSpinnerSize.lg,
            color: tokens.textSecondary,
          ),
        ),
      ),
    ),
  );
}

/// Never shown alongside an error banner: it would invite the same
/// drawing action the banner just said had failed, the timeout-freeze
/// case `canvas-error-draw-forbidden-timeout-freeze` named by name -
/// "erase the failed stroke, then show the pen tool as though nothing
/// happened" reopens the same refusal.
class CanvasEmptyHint extends StatelessWidget {
  const CanvasEmptyHint({super.key, required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppIcons.pen,
                  size: AppSizes.icon24,
                  color: tokens.textDisabled,
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  'Nothing on this canvas yet',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'Draw with the pen, drop a note or a shape, or paste an '
                  'image from "More canvas actions"',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  panZoomHint(MediaQuery.sizeOf(context).width),
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Labels the surface for a screen reader and lays the loading or empty hint
/// over it, never over an error banner or a call's participant tiles.
class CanvasSurfaceStatus extends StatelessWidget {
  const CanvasSurfaceStatus({
    super.key,
    required this.document,
    required this.tokens,
    required this.loading,
    required this.hasError,
    required this.hasCallParticipants,
    required this.child,
  });

  final CanvasDocument document;
  final AppTokens tokens;
  final bool loading;
  final bool hasError;
  final bool hasCallParticipants;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: document.objectCount,
    builder: (context, count, child) => Semantics(
      container: true,
      label: loading ? 'Canvas, loading' : 'Canvas, ${canvasSummary(document)}',
      child: Stack(
        children: [
          child!,
          // A blank canvas otherwise looks identical to a broken one; this is the sighted half of the screen-reader label above.
          if (loading)
            CanvasLoadingHint(tokens: tokens)
          // Not over an error banner, nor over a call's tiles, where "nothing here yet" contradicts the video already on screen.
          else if (count == 0 && !hasError && !hasCallParticipants)
            CanvasEmptyHint(tokens: tokens),
        ],
      ),
    ),
    child: child,
  );
}
