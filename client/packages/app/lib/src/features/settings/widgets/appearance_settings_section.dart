// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The appearance pane: the theme and high contrast, the background, text and
/// layout, then the message display controls.
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../routing/routes.dart';
import '../providers/display_density.dart';
import '../providers/display_preferences.dart';
import '../providers/stored_theme.dart';
import 'background_settings_card.dart';
import 'display_settings_section.dart';
import 'settings_section_header.dart';
import 'settings_segmented_row.dart';
import 'settings_select_row.dart';
import 'settings_slider_row.dart';
import 'settings_toggle_row.dart';
import 'theme_swatch.dart';

class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _themeCard(context, ref),
        const BackgroundSettingsCard(),
        _textAndLayoutCard(ref),
        const DisplaySettingsSection(),
      ],
    );
  }

  static const themeRowKey = Key('appearance_theme_row');

  Widget _themeCard(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(themeControllerProvider);
    final custom = ref.watch(customThemeProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      title: 'Theme',
      children: [
        AppListRow(
          key: themeRowKey,
          label: 'Color theme',
          meta: choice == AppThemeChoice.custom && custom != null
              ? custom.name
              : themeLabel(choice),
          trailing: Icon(
            AppIcons.chevronRight,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
          onTap: () => unawaited(context.push(Routes.personalThemes)),
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
        SettingsSegmentedRow<TimeFormatPreference>(
          label: 'Clock',
          value: timeFormat,
          choices: [
            for (final option in TimeFormatPreference.values)
              SettingsChoice(value: option, label: _timeFormatLabel(option)),
          ],
          onChanged: (next) =>
              ref.read(timeFormatControllerProvider.notifier).select(next),
        ),
        SettingsSegmentedRow<MotionOverride>(
          label: 'Motion',
          value: motion,
          choices: [
            for (final option in MotionOverride.values)
              SettingsChoice(value: option, label: _motionLabel(option)),
          ],
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
    MotionOverride.alwaysReduce => 'Reduced',
    MotionOverride.neverReduce => 'Full',
  };
}
