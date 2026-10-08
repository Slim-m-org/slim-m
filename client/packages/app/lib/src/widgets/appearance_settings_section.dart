// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The appearance picker: follow the system, light, dark, or true black; the
/// clock's 12/24-hour format; an in-app override of reduce-motion; and a
/// high-contrast toggle for the text/border tokens that read weakest.
///
/// Its own file rather than another section inside `settings_screen.dart`,
/// which is already past the project's line budget, and for the same reason
/// the avatar section has one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_preferences.dart';
import '../providers/providers.dart';
import 'display_settings_section.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';

/// A select row rather than segmented cards. Four cards on a phone wrap their
/// labels mid-word, which is how "Online" rendered as "Onlin e" in the
/// presence picker next door, and they cost four rows of height to say one
/// thing.
class AppearanceSettingsSection extends ConsumerWidget {
  const AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_appearanceCard(ref), const DisplaySettingsSection()],
    );
  }

  Widget _appearanceCard(WidgetRef ref) {
    final choice = ref.watch(themeControllerProvider);
    final timeFormat = ref.watch(timeFormatControllerProvider);
    final motion = ref.watch(motionPreferenceControllerProvider);
    final highContrast = ref.watch(highContrastControllerProvider);

    return SettingsSectionCard(
      divided: true,
      children: [
        SettingsSelectRow<AppThemeChoice>(
          label: 'Theme',
          value: choice,
          choices: [
            for (final option in AppThemeChoice.values)
              SettingsChoice(value: option, label: _themeLabel(option)),
          ],
          sheetFootnote: 'System follows your device.',
          onChanged: (next) =>
              ref.read(themeControllerProvider.notifier).select(next),
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
        _HighContrastRow(
          enabled: highContrast,
          onChanged: (next) =>
              ref.read(highContrastControllerProvider.notifier).select(next),
        ),
      ],
    );
  }

  String _themeLabel(AppThemeChoice choice) => switch (choice) {
    AppThemeChoice.system => 'System',
    AppThemeChoice.light => 'Light',
    AppThemeChoice.dark => 'Dark',
    AppThemeChoice.trueBlack => 'True black',
  };

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

/// A toggle rather than a select row: there is no third choice to name.
///
/// This was the one boolean setting already built the right way, as an
/// [AppListRow] with a trailing [AppToggle], while two others hand-rolled the
/// same thing. It is a [SettingsToggleRow] now so all three agree; that
/// widget carries this row's own "no row-wide onTap" reasoning forward.
class _HighContrastRow extends StatelessWidget {
  const _HighContrastRow({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SettingsToggleRow(
    label: 'High contrast',
    value: enabled,
    onChanged: onChanged,
    semanticLabel: 'High contrast',
  );
}
