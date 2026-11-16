// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A theme's bars miniature framed as a small thumbnail: Start from's 40 px
/// and a theme sheet title's 48 px.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_miniature.dart';

class ThemeMiniatureThumb extends StatelessWidget {
  const ThemeMiniatureThumb({super.key, required this.child, this.width = 40});

  ThemeMiniatureThumb.forDocument(
    ThemeDocument document, {
    super.key,
    this.width = 40,
  }) : child = ThemeMiniature.forDocument(document);

  /// The bars miniature, or what stands in for one that cannot be painted.
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.control / 2);
    return SizedBox(
      width: width,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: tokens.borderSubtle),
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}
