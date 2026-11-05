// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One group of the theme editor's colours: a row per token, and the picker
/// opening under the row you tapped on a wide window.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';
import 'settings_slider_row.dart';

class ThemeTokenGroupCard extends StatelessWidget {
  const ThemeTokenGroupCard({
    super.key,
    required this.group,
    required this.colours,
    required this.failing,
    required this.openToken,
    required this.onTap,
    required this.onPreview,
    required this.onSave,
    required this.onCancel,
    required this.onOpacity,
  });

  final ThemeTokenGroup group;
  final Map<String, Color> colours;

  /// Tokens that take part in a failing contrast check.
  final Set<String> failing;

  /// The token whose picker is open inline, or null (always null on a phone, which opens a sheet).
  final String? openToken;
  final ValueChanged<String> onTap;
  final void Function(String token, Color colour) onPreview;
  final void Function(String token, Color colour) onSave;
  final ValueChanged<String> onCancel;
  final void Function(String token, double opacity) onOpacity;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    key: Key('theme-group-${group.title}'),
    title: group.title,
    children: [
      for (final token in group.tokens) ...[
        _TokenRow(
          token: token,
          colour: colours[token]!,
          failing: failing.contains(token),
          onTap: () => onTap(token),
        ),
        if (token == openToken)
          SettingsCardBlock(
            children: [
              AppColourPicker(
                key: Key('theme-picker-$token'),
                initial: colours[token]!.withValues(alpha: 1),
                onChanged: (c) => onPreview(token, c),
                onSave: (c) => onSave(token, c),
                onCancel: () => onCancel(token),
              ),
            ],
          ),
        if (themeAlphaTokens.contains(token))
          SettingsSliderRow(
            sliderKey: Key('theme-opacity-$token'),
            label: '${themeTokenLabels[token]} opacity',
            valueLabel: '${(colours[token]!.a * 100).round()}%',
            value: colours[token]!.a,
            min: 0,
            max: 1,
            minLabel: '0%',
            maxLabel: '100%',
            divisions: 20,
            onChanged: (v) => onOpacity(token, v),
          ),
      ],
    ],
  );
}

class _TokenRow extends StatelessWidget {
  const _TokenRow({
    required this.token,
    required this.colour,
    required this.failing,
    required this.onTap,
  });

  final String token;
  final Color colour;
  final bool failing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      key: Key('theme-token-$token'),
      label: themeTokenLabels[token]!,
      meta: hexOfColour(colour),
      leading: DecoratedBox(
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: tokens.borderStrong),
        ),
        child: const SizedBox.square(dimension: AppSizes.icon24),
      ),
      trailing: failing
          ? Icon(
              AppIcons.warning,
              size: AppSizes.icon16,
              color: tokens.dangerText,
            )
          : null,
      onTap: onTap,
    );
  }
}
