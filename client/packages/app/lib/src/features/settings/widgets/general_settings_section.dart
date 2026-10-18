// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The general pane: how the desktop app starts. Start on login and the
/// startup splash only exist on the desktop shell, so the pane is only listed
/// there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;

import '../../../providers/desktop_splash_preference.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import '../../../widgets/start_on_login_row.dart';

class GeneralSettingsSection extends ConsumerWidget {
  const GeneralSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isDesktopHost)
          SettingsSectionCard(
            title: 'Startup',
            children: [const StartOnLoginRow(), _splashRow(ref)],
          ),
      ],
    );
  }

  /// One row rather than an on/off toggle: Disabled is just the first
  /// duration choice, so off and how-long are the same control.
  Widget _splashRow(WidgetRef ref) {
    return SettingsSelectRow<SplashDuration>(
      label: 'Startup splash',
      sheetTitle: 'Startup splash',
      value: ref.watch(splashDurationControllerProvider),
      choices: [
        for (final value in SplashDuration.values)
          SettingsChoice(value: value, label: value.label),
      ],
      sheetFootnote: 'The shortest time the splash stays up at startup.',
      onChanged: (next) =>
          ref.read(splashDurationControllerProvider.notifier).select(next),
    );
  }
}
