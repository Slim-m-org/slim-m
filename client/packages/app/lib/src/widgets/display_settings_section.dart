// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The density, group spacing and interface scale controls with their live
/// preview (decision 0062), grouped under Appearance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_density.dart';
import 'display_density_preview.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';

class DisplaySettingsSection extends ConsumerWidget {
  const DisplaySettingsSection({super.key});

  static const Key spacingSliderKey = Key('group_spacing_slider');
  static const Key scaleSliderKey = Key('ui_scale_slider');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(messageDensityControllerProvider);
    final spacing = ref.watch(groupSpacingControllerProvider);
    final scale = ref.watch(uiScaleControllerProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionCard(
          title: 'Messages',
          description: 'How tight messages sit, and how far apart groups are.',
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSelectRow<AppDensity>(
              label: 'Message density',
              value: density,
              choices: [
                for (final option in AppDensity.values)
                  SettingsChoice(value: option, label: _label(option)),
              ],
              onChanged: (next) => ref
                  .read(messageDensityControllerProvider.notifier)
                  .select(next),
            ),
            const SizedBox(height: AppSpacing.s8),
            DisplayDensityPreview(density: density, groupSpacing: spacing),
            const SizedBox(height: AppSpacing.s16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Text(
                'Group spacing',
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
            AppSlider(
              key: spacingSliderKey,
              value: spacing.toDouble(),
              min: groupSpacingSteps.first.toDouble(),
              max: groupSpacingSteps.last.toDouble(),
              divisions: groupSpacingSteps.length - 1,
              ticks: [for (final s in groupSpacingSteps) '$s'],
              semanticLabel: 'Space between message groups',
              onChanged: (v) => ref
                  .read(groupSpacingControllerProvider.notifier)
                  .select(v.round()),
            ),
          ],
        ),
        SettingsSectionCard(
          title: 'Interface scale',
          description: 'Make everything larger or smaller.',
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSlider(
              key: scaleSliderKey,
              value: scale.toDouble(),
              min: uiScaleMin.toDouble(),
              max: uiScaleMax.toDouble(),
              divisions: (uiScaleMax - uiScaleMin) ~/ uiScaleStep,
              ticks: [for (var p = uiScaleMin; p <= uiScaleMax; p += 10) '$p%'],
              semanticLabel: 'Interface scale',
              onChanged: (v) => ref
                  .read(uiScaleControllerProvider.notifier)
                  .select(v.round()),
            ),
          ],
        ),
      ],
    );
  }

  String _label(AppDensity d) => switch (d) {
    AppDensity.compact => 'Compact',
    AppDensity.normal => 'Default',
    AppDensity.spacious => 'Spacious',
  };
}
