// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Third-party service marks (Simple Icons, CC0; see `assets/brand_logos/SOURCE.md`).
///
/// These name a service and are content, not interface chrome, so they sit
/// beside [AppIcons] rather than in it. Every call site goes through [BrandLogo].
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum BrandService {
  spotify('spotify', Color(0xFF1DB954), 'Spotify'),
  discord('discord', Color(0xFF5865F2), 'Discord');

  const BrandService(this.asset, this.colour, this.label);

  final String asset;
  final Color colour;
  final String label;
}

class BrandLogo extends StatelessWidget {
  const BrandLogo(
    this.service, {
    super.key,
    this.size = 20,
    this.monochrome,
  });

  final BrandService service;
  final double size;

  /// Draws the mark in this single colour instead of the brand colour.
  final Color? monochrome;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SvgPicture.asset(
        'assets/brand_logos/${service.asset}.svg',
        package: 'slimm_design_system',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(
          monochrome ?? service.colour,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}
