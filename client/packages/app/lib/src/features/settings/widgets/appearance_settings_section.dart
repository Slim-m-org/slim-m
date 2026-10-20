// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The appearance pane: the theme cards and high contrast, the message
/// density controls, then interface scale, clock format and reduce-motion.
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_preferences.dart';
import '../../../providers/providers.dart';
import 'display_settings_section.dart';
import '../providers/display_density.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_slider_row.dart';
import 'settings_toggle_row.dart';
import 'theme_choice_cards.dart';

class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _themeCard(ref),
        const DisplaySettingsSection(),
        _textAndLayoutCard(ref),
      ],
    );
  }

  Widget _themeCard(WidgetRef ref) {
    return SettingsSectionCard(
      title: 'Theme',
      children: [
        SettingsCardBlock(
          children: [
            ThemeChoiceCards(
              selected: ref.watch(themeControllerProvider),
              onChanged: (next) =>
                  ref.read(themeControllerProvider.notifier).select(next),
            ),
          ],
        ),
        SettingsToggleRow(
          label: 'High contrast',
          description: 'Stronger borders and text.',
          value: ref.watch(highContrastControllerProvider),
          semanticLabel: 'High contrast',
          onChanged: (next) =>
              ref.read(highContrastControllerProvider.notifier).select(next),
        ),
      ],
    );
  }

  Widget _textAndLayoutCard(WidgetRef ref) {
    final scale = ref.watch(uiScaleControllerProvider);
    final timeFormat = ref.watch(timeFormatControllerProvider);
    final motion = ref.watch(motionPreferenceControllerProvider);

    return SettingsSectionCard(
      title: 'Text and layout',
      children: [
        SettingsSliderRow(
          sliderKey: DisplaySettingsSection.scaleSliderKey,
          label: 'Interface scale',
          valueLabel: '$scale%',
          value: scale.toDouble(),
          min: uiScaleMin.toDouble(),
          max: uiScaleMax.toDouble(),
          minLabel: '$uiScaleMin%',
          maxLabel: '$uiScaleMax%',
          divisions: (uiScaleMax - uiScaleMin) ~/ uiScaleStep,
          onChanged: (v) =>
              ref.read(uiScaleControllerProvider.notifier).select(v.round()),
        ),
        SettingsSelectRow<TimeFormatPreference>(
          label: 'Clock',
          sheetTitle: 'Time format',
          value: timeFormat,
          choices: [
            for (final option in TimeFormatPreference.values)
              SettingsChoice(value: option, label: _timeFormatLabel(option)),
          ],
          sheetFootnote: 'System follows your device clock.',
          onChanged: (next) =>
              ref.read(timeFormatControllerProvider.notifier).select(next),
        ),
        SettingsSelectRow<MotionOverride>(
          label: 'Motion',
          sheetTitle: 'Reduce motion',
          value: motion,
          choices: [
            for (final option in MotionOverride.values)
              SettingsChoice(value: option, label: _motionLabel(option)),
          ],
          sheetFootnote: 'System follows your device motion setting.',
          onChanged: (next) => ref
              .read(motionPreferenceControllerProvider.notifier)
              .select(next),
        ),
      ],
    );
  }

  String _timeFormatLabel(TimeFormatPreference pref) => switch (pref) {
    TimeFormatPreference.system => 'System',
    TimeFormatPreference.h12 => '12-hour',
    TimeFormatPreference.h24 => '24-hour',
  };

  String _motionLabel(MotionOverride choice) => switch (choice) {
    MotionOverride.system => 'System',
    MotionOverride.alwaysReduce => 'Always reduce',
    MotionOverride.neverReduce => 'Never reduce',
  };
}
