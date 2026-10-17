// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The box a module's scene is drawn in, sized to the room it is given.
///
/// Two complaints shaped this, in opposite directions. A fixed 420px cap was
/// "a small square adrift" in a desktop card twice its width. Removing it for
/// a share of the window height then made a three-by-three board 650px tall
/// on a 1080p desktop, which the owner read as huge.
///
/// What reconciles them is that neither size is about the window: it is about
/// how big one cell has to be. A board is bounded by [maxCellSize] per cell,
/// so a tic-tac-toe grid stays a board rather than a billboard while a
/// forty-square life grid is still limited by the window as before. The
/// height share remains the outer bound, so no scene can push the transcript
/// off screen, and the width follows from the scene's own aspect ratio.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ModuleSceneFrame extends StatelessWidget {
  const ModuleSceneFrame({
    super.key,
    required this.aspect,
    required this.child,
    this.sceneHeight = 0,
    this.fillAvailable = false,
    this.cardWidth,
  });

  /// The room the card around this frame was offered, when the frame is already
  /// narrowed to its own size and would otherwise read that as the card's.
  final double? cardWidth;

  /// Width over height of the scene's own coordinate space; anything at or
  /// below zero is treated as square.
  final double aspect;

  /// The scene's own height in its coordinate space, which for a cell grid
  /// is the row count. That is what decides whether a scene wants the room a
  /// big grid needs. Zero or less falls back to the window bound alone.
  final double sceneHeight;

  final Widget child;

  /// Take all the room there is, rather than the share an inline board gets.
  ///
  /// Every bound below exists because a scene sits in a transcript that has to
  /// stay readable around it. On a screen of its own there is nothing to stay
  /// readable around, so a board that still capped itself at 160px a cell
  /// would be a small square adrift in a large window - the exact complaint
  /// the cap was added to fix, arrived at from the other direction.
  final bool fillAvailable;

  /// How much of the window a board may take before the width gives way.
  static const viewportShare = 0.6;

  /// The floor under that share, so a short window still gets a usable
  /// board rather than a sliver.
  static const minHeight = 240.0;

  /// The tallest one unit of the scene's own coordinate space may be drawn,
  /// which for a cell grid is one cell. Chosen so a three-row board lands
  /// near 480px: comfortably past the 420 that read as adrift, and well
  /// inside the 650 that read as huge. A grid with many rows is unaffected,
  /// because the window share binds long before this does.
  static const maxCellSize = 160.0;

  /// The longest an inline board may be drawn on any window, whatever its own
  /// coordinate space. The per-cell bound only exists for a grid; a scene made
  /// of rects and text declares a height in arbitrary units, so a 300 unit
  /// board never met it and took the window share instead, 650px on a
  /// 1818x1071 desktop. This is the bound that holds for every scene.
  static const maxInlineEdge = 360.0;

  /// Card widths at or below which phones' edge applies, and from which the wide one does.
  static const narrowUpTo = 480.0;
  static const wideFrom = 760.0;

  /// The inline edge on a wide card: 520 is the largest that still leaves a
  /// message's text and a second board visible in a 1080p window.
  static const maxWideInlineEdge = 520.0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ratio = aspect <= 0 ? 1.0 : aspect;
    if (fillAvailable) return _buildFilled(tokens, ratio);
    return _buildInline(context, tokens, ratio);
  }

  Widget _buildFilled(AppTokens tokens, double ratio) {
    // Not AspectRatio: given this host's tight height and merely bounded width, it re-derives width from height, has that clamped back down without revisiting height, and returns the full tight rect - so fit by hand against both bounds instead.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.maxHeight * ratio;
        final maxHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.maxWidth / ratio;
        var width = maxWidth;
        var height = width / ratio;
        if (height > maxHeight) {
          height = maxHeight;
          width = height * ratio;
        }
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: tokens.borderSubtle),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _buildInline(BuildContext context, AppTokens tokens, double ratio) {
    final windowHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final offered = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : null;
        final width = inlineWidth(
          maxWidth: cardWidth == null || offered == null
              ? offered
              : math.min(offered, cardWidth!),
          edgeWidth: cardWidth ?? offered,
          windowHeight: windowHeight,
          aspect: ratio,
          sceneHeight: sceneHeight,
        );
        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: tokens.borderSubtle),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              clipBehavior: Clip.antiAlias,
              child: AspectRatio(aspectRatio: ratio, child: child),
            ),
          ),
        );
      },
    );
  }

  /// The longest edge an inline board may have in a card [availableWidth] wide.
  ///
  /// Phones and narrow panes keep [maxInlineEdge]; from [wideFrom] up the
  /// bound grows to [maxWideInlineEdge], so a game in a desktop-width card is
  /// not a small square adrift. Chosen by width alone, never by platform.
  static double inlineEdge(double? availableWidth) {
    if (availableWidth == null) return maxInlineEdge;
    final t = ((availableWidth - narrowUpTo) / (wideFrom - narrowUpTo)).clamp(
      0.0,
      1.0,
    );
    return maxInlineEdge + (maxWideInlineEdge - maxInlineEdge) * t;
  }

  /// The width an inline scene frame takes, so the card around it can hug it.
  static double inlineWidth({
    required double? maxWidth,
    double? edgeWidth,
    required double windowHeight,
    required double aspect,
    required double sceneHeight,
  }) {
    final ratio = aspect <= 0 ? 1.0 : aspect;
    final cellBound = sceneHeight > 0
        ? sceneHeight * maxCellSize
        : double.infinity;
    final maxHeight = math.max(
      minHeight,
      math.min(
        math.min(windowHeight * viewportShare, cellBound),
        inlineEdge(edgeWidth ?? maxWidth),
      ),
    );
    final widthForHeight = maxHeight * ratio;
    return maxWidth == null
        ? widthForHeight
        : math.min(maxWidth, widthForHeight);
  }
}
