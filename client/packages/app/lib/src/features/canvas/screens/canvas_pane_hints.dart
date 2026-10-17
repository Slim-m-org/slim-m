// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two overlay hints `canvas_pane_body.dart`'s drawing surface shows in
/// place of a blank canvas: a loading spinner while the viewport fetch is
/// still in flight, and an empty-canvas prompt once it has resolved to
/// nothing. Split out once the body crossed the 500-line hard ceiling; both
/// are self-contained `Positioned.fill` overlays with no state of their own.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

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
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: tokens.textSecondary,
              value: AppMotion.isReduced(context) ? 0.75 : null,
            ),
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
