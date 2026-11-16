// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small copy of the app painted in one theme's own tokens: rail, channel
/// list with the selected channel, messages with an accent link, composer.
///
/// The one miniature every theme surface shows, from a 40 px thumbnail to the
/// editor's live preview; it never reads the ambient theme's colours.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_miniature_painter.dart';
import 'theme_miniature_text.dart';

export 'theme_miniature_painter.dart' show ThemeMiniatureGeometry;

enum ThemeMiniatureDetail {
  /// Blocks and bars at 16:10, for cards, recents and thumbnails.
  bars,

  /// Real text, for the theme in use at the top of Appearance.
  hero,

  /// Every token in a sample, for the editor's preview.
  draft,

  /// The editor's short strip on a phone.
  draftStrip,
}

class ThemeMiniature extends StatelessWidget {
  const ThemeMiniature({
    super.key,
    required this.tokens,
    this.brightness = Brightness.dark,
    this.detail = ThemeMiniatureDetail.bars,
    this.split,
    this.picture,
    this.open = 1,
  });

  factory ThemeMiniature.forDocument(
    ThemeDocument document, {
    Key? key,
    ThemeMiniatureDetail detail = ThemeMiniatureDetail.bars,
    ImageProvider? picture,
    double open = 1,
  }) => ThemeMiniature(
    key: key,
    tokens: document.tokens,
    brightness: document.brightness,
    detail: detail,
    picture: picture,
    open: open,
  );

  /// What it paints with; the ambient theme never shows through.
  final AppTokens tokens;
  final Brightness brightness;
  final ThemeMiniatureDetail detail;

  /// System's dark tokens, painted in the lower right of a diagonal from 62%
  /// along the top to 38% along the bottom.
  final AppTokens? split;

  /// Shown under the chat column, faded to the base surface; the caller sizes
  /// it to the drawn width with a [ResizeImage].
  final ImageProvider? picture;

  /// How much of the draft's foldable rows shows; see [ThemeMiniatureDraft.open].
  final double open;

  @override
  Widget build(BuildContext context) {
    final body = switch (detail) {
      ThemeMiniatureDetail.bars => _bars(),
      ThemeMiniatureDetail.hero => _hero(),
      ThemeMiniatureDetail.draft => ThemeMiniatureDraft(
        tokens: tokens,
        open: open,
      ),
      ThemeMiniatureDetail.draftStrip => ThemeMiniatureDraft(
        tokens: tokens,
        strip: true,
        open: open,
      ),
    };
    return ExcludeSemantics(child: RepaintBoundary(child: body));
  }

  Widget _hero() {
    final dark = split;
    final light = ThemeMiniatureHero(tokens: tokens);
    if (dark == null) return light;
    return Stack(
      children: [
        light,
        Positioned.fill(
          child: ClipPath(
            clipper: const _SplitClipper(),
            child: ThemeMiniatureHero(tokens: dark),
          ),
        ),
      ],
    );
  }

  Widget _bars() {
    final picture = this.picture;
    if (picture == null) {
      return AspectRatio(
        aspectRatio: ThemeMiniatureGeometry.aspect,
        child: CustomPaint(
          painter: ThemeMiniaturePainter(tokens: tokens, split: split),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: ThemeMiniatureGeometry.aspect,
      child: CustomPaint(
        painter: ThemeMiniaturePainter(
          tokens: tokens,
          split: split,
          layer: ThemeMiniatureLayer.back,
        ),
        foregroundPainter: ThemeMiniaturePainter(
          tokens: tokens,
          split: split,
          layer: ThemeMiniatureLayer.front,
        ),
        child: LayoutBuilder(
          builder: (context, box) => Padding(
            padding: EdgeInsets.only(
              left: ThemeMiniatureGeometry.chatLeft(box.maxWidth),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image(
                  image: picture,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                ColoredBox(color: tokens.surfaceBase.withValues(alpha: 0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitClipper extends CustomClipper<Path> {
  const _SplitClipper();

  @override
  Path getClip(Size size) => ThemeMiniatureGeometry.splitPath(size);

  @override
  bool shouldReclip(_SplitClipper oldClipper) => false;
}
