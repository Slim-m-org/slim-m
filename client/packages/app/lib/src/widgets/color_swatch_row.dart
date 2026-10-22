// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row of round colour swatches where the chosen one wears a ring, shared by the profile
/// colour and the role colour pickers.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The trailing "Custom" swatch: the chosen custom [colour] when there is one,
/// otherwise a neutral add button. [onTap] opens whatever picks the colour.
class CustomSwatch {
  const CustomSwatch({
    required this.label,
    required this.onTap,
    this.colour,
    this.icon,
  });

  final String label;
  final Color? colour;
  final VoidCallback? onTap;

  /// Drawn when [colour] is null; defaults to [AppIcons.add].
  final IconData? icon;
}

class ColorSwatchRow extends StatelessWidget {
  const ColorSwatchRow({
    super.key,
    required this.label,
    required this.colors,
    required this.names,
    required this.selected,
    required this.onSelect,
    this.custom,
    this.leading,
  }) : assert(colors.length == names.length);

  /// What is being chosen, read before each swatch's name, e.g. "Role colour".
  final String label;
  final List<Color> colors;
  final List<String> names;

  /// The chosen index, or null when none is.
  final int? selected;

  /// Null disables every swatch.
  final ValueChanged<int>? onSelect;

  /// An extra swatch after the presets; selected whenever it holds a colour.
  final CustomSwatch? custom;

  /// A tile ahead of the presets for a choice that is not a colour, such as an image.
  final Widget? leading;

  /// The width [count] tiles take side by side at the current touch density.
  static double widthOf(BuildContext context, int count) {
    final touch = AppTouchTargets.of(context);
    return count * (touch ? AppSizes.rowTouch : 36.0) +
        (touch ? 0 : 2 * (count - 1));
  }

  @override
  Widget build(BuildContext context) {
    final touch = AppTouchTargets.of(context);
    final onSelect = this.onSelect;
    final custom = this.custom;
    return Wrap(
      spacing: touch ? 0 : 2,
      runSpacing: touch ? 0 : 2,
      children: [
        ?leading,
        for (var i = 0; i < colors.length; i++)
          SwatchTile(
            color: colors[i],
            label: '$label: ${names[i]}',
            selected: selected == i,
            onTap: onSelect == null ? null : () => onSelect(i),
          ),
        if (custom != null)
          SwatchTile(
            color: custom.colour,
            icon: custom.icon ?? AppIcons.add,
            label: '$label: ${custom.label}',
            selected: custom.colour != null,
            onTap: custom.onTap,
          ),
      ],
    );
  }
}

/// One round tile in a [ColorSwatchRow]: a colour, a neutral icon, or a [child] such as a thumbnail.
class SwatchTile extends StatelessWidget {
  const SwatchTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.icon,
    this.child,
  });

  /// Drawn clipped to the circle in place of a colour or icon.
  final Widget? child;

  /// Null draws the neutral [icon] swatch instead of a fill.
  final Color? color;
  final IconData? icon;
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
            child: child != null
                ? ClipOval(child: child)
                : color == null
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.surfaceSunken,
                      shape: BoxShape.circle,
                      border: Border.all(color: tokens.borderStrong),
                    ),
                    child: Icon(icon, size: 16, color: tokens.textSecondary),
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
