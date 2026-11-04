// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Overview tab's one Actions card: enable, export, clear data and
/// uninstall as labelled rows. Install and update live in [DockPrimaryAction],
/// pinned under every tab.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';
import 'dock_activity_card.dart';

class DockModuleActions extends StatelessWidget {
  const DockModuleActions({
    super.key,
    required this.manifest,
    required this.installed,
    required this.busy,
    required this.onSetEnabled,
    required this.onUninstall,
    required this.onExport,
    required this.onClearStorage,
  });

  final api.DockManifest manifest;
  final api.InstalledDockModule? installed;
  final bool busy;
  final ValueChanged<bool> onSetEnabled;
  final VoidCallback onUninstall;
  final VoidCallback? onExport;
  final VoidCallback? onClearStorage;

  @override
  Widget build(BuildContext context) {
    final installed = this.installed;
    if (installed == null) return const SizedBox.shrink();
    final storage = installed.storage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Actions',
          children: [
            SettingsToggleRow(
              label: 'Enabled',
              description: 'Off keeps it installed but inactive.',
              value: installed.enabled,
              onChanged: busy ? null : onSetEnabled,
              semanticLabel: installed.enabled
                  ? '${manifest.name} enabled'
                  : '${manifest.name} disabled',
            ),
            if (onExport != null)
              SettingsDetailRow(
                title: 'Package file',
                detail: 'Save it without its settings or data.',
                trailing: AppButton(
                  label: 'Export',
                  icon: AppIcons.download,
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  disabled: busy,
                  onPressed: onExport,
                ),
              ),
            if (onClearStorage != null && storage != null)
              SettingsDetailRow(
                title: 'Stored data',
                detail:
                    '${storage.entries} of ${storage.maxEntries} entries, '
                    '${dockBytes(storage.bytes)} of '
                    '${dockBytes(storage.maxBytes)}',
                trailing: AppButton(
                  label: 'Clear data',
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  semanticLabel: 'Clear stored data',
                  disabled: busy || storage.entries == 0,
                  onPressed: onClearStorage,
                ),
              ),
            SettingsDetailRow(
              title: 'Remove from this space',
              detail: 'Also removes its permissions and role grants.',
              trailing: AppButton(
                label: 'Uninstall',
                variant: AppButtonVariant.danger,
                size: AppButtonSize.sm,
                disabled: busy,
                onPressed: onUninstall,
              ),
            ),
          ],
        ),
      ],
    );
  }
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
