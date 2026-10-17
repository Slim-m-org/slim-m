// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row of round colour swatches where the chosen one wears a ring, shared by the profile
/// colour and the role colour pickers.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ColorSwatchRow extends StatelessWidget {
  const ColorSwatchRow({
    super.key,
    required this.label,
    required this.colors,
    required this.names,
    required this.selected,
    required this.onSelect,
  }) : assert(colors.length == names.length);

  /// What is being chosen, read before each swatch's name, e.g. "Role colour".
  final String label;
  final List<Color> colors;
  final List<String> names;

  /// The chosen index, or null when none is.
  final int? selected;

  /// Null disables every swatch.
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final touch = AppTouchTargets.of(context);
    final onSelect = this.onSelect;
    return Wrap(
      spacing: touch ? 0 : 2,
      runSpacing: touch ? 0 : 2,
      children: [
        for (var i = 0; i < colors.length; i++)
          _ColorSwatch(
            color: colors[i],
            label: '$label: ${names[i]}',
            selected: selected == i,
            onTap: onSelect == null ? null : () => onSelect(i),
          ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final side = AppTouchTargets.of(context) ? AppSizes.rowTouch : 36.0;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: side,
          height: side,
          alignment: Alignment.center,
          child: Container(
            width: 36,
            height: 36,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? tokens.textPrimary : Colors.transparent,
                width: 2,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}
