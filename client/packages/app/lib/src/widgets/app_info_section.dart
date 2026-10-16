// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which build this is, for a tester to read off the device rather than
/// asking whoever is looking at it what they have installed.
///
/// Lives in personal settings, not on a screen of its own: it is the same for
/// every account signed into this install and every Space it connects to, and
/// personal settings is the one screen every signed-in caller can always
/// reach. The debug log is reached from Troubleshooting, not from here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/auto_update_preference.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';
import 'update_status_rows.dart';
import 'whats_new_sheet.dart';

class AppInfoSection extends ConsumerWidget {
  const AppInfoSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        const UpdateStatusRows(),
        SettingsSectionCard(
          title: 'Updates',
          children: [
            // Desktop only: a store build and the web page are updated by the store and the browser (decision 0025).
            if (isDesktopHost)
              SettingsToggleRow(
                label: 'Automatic updates',
                description: automaticUpdatesDescription(
                  currentInstallFormat(),
                ),
                value: ref.watch(autoUpdateProvider),
                semanticLabel: 'Automatic updates',
                onChanged: (v) =>
                    unawaited(ref.read(autoUpdateProvider.notifier).set(v)),
              ),
            AppListRow(
              label: 'Release notes',
              subtitle: 'What changed in every version.',
              trailing: const Icon(
                AppIcons.chevronRight,
                size: AppSizes.icon16,
              ),
              onTap: () => unawaited(showReleaseNotesSheet(context)),
            ),
          ],
        ),
      ],
    );
  }
}

/// What turning the switch on actually does here, which differs by install
/// format - dnf can install it, a flatpak or a tarball can only be pointed
/// at. See `startup_updates.dart` for the splash pass this controls.
String automaticUpdatesDescription(InstallFormat format) => switch (format) {
  InstallFormat.rpm || InstallFormat.deb =>
    'Install a new version with your package manager while slim-m starts.',
  InstallFormat.flatpak ||
  InstallFormat.appImage ||
  InstallFormat.tarball ||
  InstallFormat.apk ||
  InstallFormat.unknown =>
    'Tell me at startup when a new version is available.',
};
