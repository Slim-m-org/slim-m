// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A theme colour as a small square, edged so a colour like its surface still
/// shows: the editor's rows, tiles, group strips and contrast rows share it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeColourChip extends StatelessWidget {
  const ThemeColourChip({
    super.key,
    required this.colour,
    this.size = AppSizes.icon24,
  });

  final Color colour;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(AppRadii.control / 2),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: SizedBox.square(dimension: size),
    );
  }
}
