// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module page's controls: Enabled and who may use it at the top, Uninstall
/// at the bottom, and Install or Update in [DockPrimaryAction], pinned below.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';
import 'dock_role_access_card.dart';

/// The two things an admin reaches for first: whether it runs, and who may use it.
class DockModuleControls extends StatelessWidget {
  const DockModuleControls({
    super.key,
    required this.manifest,
    required this.installed,
    required this.busy,
    required this.onSetEnabled,
    this.rolesOpen = false,
  });

  final api.DockManifest manifest;
  final api.InstalledDockModule installed;
  final bool busy;
  final ValueChanged<bool> onSetEnabled;

  /// Opens the role switches, right after a first install.
  final bool rolesOpen;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    topGap: AppSpacing.s16,
    children: [
      SettingsToggleRow(
        label: 'Enabled',
        value: installed.enabled,
        onChanged: busy ? null : onSetEnabled,
        semanticLabel: installed.enabled
            ? '${manifest.name} enabled'
            : '${manifest.name} disabled',
      ),
      DockRoleAccessCard(
        key: ValueKey(rolesOpen),
        manifest: manifest,
        initiallyExpanded: rolesOpen,
      ),
    ],
  );
}

/// The one irreversible action, alone at the bottom of the page.
class DockUninstallRow extends StatelessWidget {
  const DockUninstallRow({
    super.key,
    required this.busy,
    required this.onUninstall,
  });

  final bool busy;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    children: [
      SettingsDetailRow(
        title: 'Remove from this space',
        detail: 'Its permissions and role grants go too.',
        trailing: AppButton(
          label: 'Uninstall',
          variant: AppButtonVariant.danger,
          size: AppButtonSize.sm,
          disabled: busy,
          onPressed: onUninstall,
        ),
      ),
    ],
  );
}

/// Install, or update to the marketplace's version: the same call either way,
/// since re-installing at a new version is what an update is. Null when there
/// is nothing to do.
class DockPrimaryAction extends StatelessWidget {
  const DockPrimaryAction({
    super.key,
    required this.manifest,
    required this.installed,
    required this.busy,
    required this.onPressed,
  });

  final api.DockManifest manifest;
  final api.InstalledDockModule? installed;
  final bool busy;
  final VoidCallback onPressed;

  /// Whether there is anything to install or update.
  bool get visible =>
      installed == null || installed!.version != manifest.version;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final label = installed == null
        ? (busy ? 'Installing...' : 'Install v${manifest.version}')
        : (busy ? 'Updating...' : 'Update to v${manifest.version}');
    return AppButton(
      label: label,
      variant: AppButtonVariant.primary,
      full: true,
      disabled: busy,
      onPressed: onPressed,
    );
  }
}
