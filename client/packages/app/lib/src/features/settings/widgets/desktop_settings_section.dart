// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Desktop pane: how the desktop app behaves around the window, kept apart from what it shows, and its call shortcuts.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../desktop/providers/close_to_tray_preference.dart';
import '../../../desktop/providers/desktop_splash_preference.dart';
import '../../voice/widgets/voice_shortcuts_section.dart';
import 'start_on_login_row.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';

class DesktopSettingsSection extends StatelessWidget {
  const DesktopSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        SettingsSectionCard(
          title: 'Startup',
          children: [StartOnLoginRow(), _StartupSplashRow()],
        ),
        SettingsSectionCard(title: 'Window', children: [_CloseToTrayRow()]),
        VoiceShortcutsSection(),
      ],
    );
  }
}

class _CloseToTrayRow extends ConsumerWidget {
  const _CloseToTrayRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsToggleRow(
      label: 'Close to tray',
      description: 'Closing the window keeps slim-m running in the tray.',
      semanticLabel: 'Close to tray',
      value: ref.watch(closeToTrayProvider),
      onChanged: (on) =>
          unawaited(ref.read(closeToTrayProvider.notifier).set(on)),
    );
  }
}

/// One select rather than a toggle: Disabled is the first duration, so off and how-long are one control.
class _StartupSplashRow extends ConsumerWidget {
  const _StartupSplashRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSelectRow<SplashDuration>(
      label: 'Startup splash',
      sheetTitle: 'Startup splash',
      value: ref.watch(splashDurationControllerProvider),
      choices: [
        for (final value in SplashDuration.values)
          SettingsChoice(value: value, label: value.label),
      ],
      description: 'How long the splash shows when the app opens.',
      onChanged: (next) =>
          ref.read(splashDurationControllerProvider.notifier).select(next),
    );
  }
}
