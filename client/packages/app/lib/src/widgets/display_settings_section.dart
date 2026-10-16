// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The density, group spacing and thread line controls with their live
/// preview (decision 0062), grouped under Appearance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_density.dart';
import 'display_density_preview.dart';
import 'settings_section_header.dart';
import 'settings_segmented_row.dart';
import 'settings_select_row.dart';
import 'settings_slider_row.dart';

class DisplaySettingsSection extends ConsumerWidget {
  const DisplaySettingsSection({super.key});

  static const Key spacingSliderKey = Key('group_spacing_slider');
  static const Key scaleSliderKey = Key('ui_scale_slider');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = ref.watch(messageDensityControllerProvider);
    final spacing = ref.watch(groupSpacingControllerProvider);
    final marker = ref.watch(continuationMarkerControllerProvider);

    return SettingsSectionCard(
      title: 'Messages',
      description: 'How tight messages sit, and how far apart groups are.',
      children: [
        DisplayDensityPreview(
          density: density,
          groupSpacing: spacing,
          marker: marker,
        ),
        SettingsSegmentedRow<AppDensity>(
          label: 'Density',
          value: density,
          choices: [
            for (final option in AppDensity.values)
              SettingsChoice(value: option, label: _label(option)),
          ],
          onChanged: (next) =>
              ref.read(messageDensityControllerProvider.notifier).select(next),
        ),
        SettingsSliderRow(
          sliderKey: spacingSliderKey,
          label: 'Space between groups',
          valueLabel: '$spacing px',
          value: spacing.toDouble(),
          min: groupSpacingSteps.first.toDouble(),
          max: groupSpacingSteps.last.toDouble(),
          minLabel: '${groupSpacingSteps.first}',
          maxLabel: '${groupSpacingSteps.last}',
          divisions: groupSpacingSteps.length - 1,
          onChanged: (v) => ref
              .read(groupSpacingControllerProvider.notifier)
              .select(v.round()),
        ),
        SettingsSegmentedRow<ContinuationMarker>(
          label: 'Thread lines',
          description: 'Join a run of messages from one person with a line.',
          value: marker,
          choices: [
            for (final option in ContinuationMarker.values)
              SettingsChoice(value: option, label: _markerLabel(option)),
          ],
          onChanged: (next) => ref
              .read(continuationMarkerControllerProvider.notifier)
              .select(next),
        ),
      ],
    );
  }

  String _markerLabel(ContinuationMarker m) => switch (m) {
    ContinuationMarker.none => 'None',
    ContinuationMarker.clean => 'Clean',
    ContinuationMarker.tree => 'Tree',
  };

  String _label(AppDensity d) => switch (d) {
    AppDensity.compact => 'Compact',
    AppDensity.normal => 'Default',
    AppDensity.spacious => 'Spacious',
  };
}
