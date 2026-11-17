// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The parts a gallery card and the Not saved card share: the frame with its
/// In use ring, the In use check, the placeholder for a theme that cannot be
/// applied, and the 28 px pencil or kebab.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_gallery.dart';
import 'theme_miniature_painter.dart';

/// A card on the raised surface with a hairline edge, which turns strong on
/// hover and becomes a 2 px accent ring while the theme is in use.
///
/// The edge is painted over the content, so a ring never moves the name.
class ThemeCardFrame extends StatelessWidget {
  const ThemeCardFrame({
    super.key,
    required this.inUse,
    required this.child,
    this.hovered = false,
    this.focused = false,
  });

  final bool inUse;
  final bool hovered;
  final bool focused;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.card);
    final (colour, width) = focused
        ? (tokens.focusRing, 2.0)
        : inUse
        ? (tokens.accentFill, 2.0)
        : (hovered ? tokens.borderStrong : tokens.borderSubtle, 1.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: radius,
      ),
      position: DecorationPosition.background,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(color: colour, width: width),
          borderRadius: radius,
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// The check at the top right of the card in use.
class ThemeInUseBadge extends StatelessWidget {
  const ThemeInUseBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Container(
        width: AppSizes.icon20,
        height: AppSizes.icon20,
        decoration: BoxDecoration(
          color: tokens.accentFill,
          shape: BoxShape.circle,
        ),
        child: Icon(
          AppIcons.check,
          size: AppSizes.icon12,
          color: tokens.accentOn,
        ),
      ),
    );
  }
}

/// Where a miniature would be for a theme that cannot be applied: sunken,
/// striped, with the reason.
class ThemeBrokenPlaceholder extends StatelessWidget {
  const ThemeBrokenPlaceholder({
    super.key,
    required this.broken,
    this.compact = false,
  });

  final ThemeBroken broken;

  /// A thumbnail: the icon alone.
  final bool compact;

  static String reason(ThemeBroken broken) => switch (broken) {
    ThemeBroken.contrast => 'Fails a contrast check.',
    ThemeBroken.unreadable => 'Cannot be read.',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final icon = Icon(
      AppIcons.warning,
      size: compact ? AppSizes.icon16 : AppSizes.icon20,
      color: tokens.warnText,
    );
    return AspectRatio(
      aspectRatio: ThemeMiniatureGeometry.aspect,
      child: CustomPaint(
        painter: _Stripes(tokens.surfaceSunken, tokens.borderSubtle),
        child: Center(
          child: compact
              ? icon
              : Padding(
                  padding: const EdgeInsets.all(AppSpacing.s12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: AppSpacing.s8,
                    children: [
                      icon,
                      ExcludeSemantics(
                        child: Text(
                          '${reason(broken)}\nCannot be applied.',
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _Stripes extends CustomPainter {
  const _Stripes(this.fill, this.line);

  /// Nine apart across the stripes, which run at 45 degrees.
  static const _step = 12.7;

  final Color fill;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = fill);
    final paint = Paint()
      ..color = line
      ..strokeWidth = 1;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width; x += _step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Stripes old) => old.fill != fill || old.line != line;
}

/// A card's 28 px pencil or kebab; a finger reaches it from a 44 square.
class ThemeCardButton extends StatelessWidget {
  const ThemeCardButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AppTouchHitArea(
    child: AppIconButton(
      icon: icon,
      semanticLabel: label,
      tooltip: tooltip,
      touch: false,
      iconSize: AppSizes.icon16,
      onPressed: onPressed,
    ),
  );
}
