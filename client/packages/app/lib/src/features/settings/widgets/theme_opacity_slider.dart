// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A see-through theme colour's opacity in 5% steps, with its value at the
/// right: inside the picker, and under the colour in a phone's colour group.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeOpacitySlider extends StatelessWidget {
  const ThemeOpacitySlider({
    super.key,
    required this.token,
    required this.value,
    required this.onChanged,
    this.sliderKey,
  });

  final String token;
  final double value;
  final ValueChanged<double> onChanged;
  final Key? sliderKey;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final caption = AppText.caption.copyWith(color: tokens.textSecondary);
    return Row(
      spacing: AppSpacing.s12,
      children: [
        Text('Opacity', style: caption),
        Expanded(
          child: AppSlider(
            key: sliderKey,
            value: value,
            min: 0,
            max: 1,
            divisions: 20,
            semanticLabel: '${themeTokenLabels[token]} opacity',
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.end,
            style: caption.copyWith(fontFamily: AppFonts.mono),
          ),
        ),
      ],
    );
  }
}
