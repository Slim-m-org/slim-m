// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The folded Details section at the foot of a module page: what it adds,
/// the permissions it registers, run limits, activity, checks, stored data
/// and export. Kept out of the way because an admin rarely acts on them.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_activity_card.dart';
import 'dock_changelog_card.dart';
import 'dock_command_panel_group.dart';
import 'dock_hooks_card.dart';
import 'dock_limits_card.dart';
import 'dock_what_it_adds.dart';

class DockModuleDetails extends StatefulWidget {
  const DockModuleDetails({
    super.key,
    required this.manifest,
    required this.installed,
    required this.busy,
    required this.showChangelog,
    this.onExport,
    this.onClearStorage,
  });

  final api.DockManifest manifest;
  final api.InstalledDockModule? installed;
  final bool busy;

  /// False when the page already shows the changelog beside an update.
  final bool showChangelog;
  final VoidCallback? onExport;
  final VoidCallback? onClearStorage;

  @override
  State<DockModuleDetails> createState() => _DockModuleDetailsState();
}

class _DockModuleDetailsState extends State<DockModuleDetails> {
  bool _expanded = false;

  /// Bare commands an admin can only reach from here: the module surfaces no
  /// slash command, app or code runner that would run them in chat.
  List<api.DockExtensionPoint> get _unreachableCommands {
    final it = widget.installed;
    if (it == null || !it.enabled) return const [];
    final points = it.extensionPoints;
    if (points.any((ep) => ep.kind != 'command')) return const [];
    return points;
  }

  bool get _hasHooks =>
      widget.installed != null &&
      (widget.manifest.interceptors.isNotEmpty ||
          widget.manifest.permissionHooks.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final it = widget.installed;
    final commands = _unreachableCommands;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          children: [
            AppListRow(
              key: const Key('dock-details-toggle'),
              label: 'Details',
              semanticLabel: 'Details, ${_expanded ? 'expanded' : 'collapsed'}',
              trailing: Icon(
                _expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ),
        if (_expanded) ...[
          if (widget.manifest.extensionPoints.any((ep) => ep.kind != 'command'))
            DockWhatItAddsCard(
              extensionPoints: widget.manifest.extensionPoints,
            ),
          _PermissionsCard(permissions: widget.manifest.permissions),
          if (widget.showChangelog)
            DockChangelogCard(
              manifest: widget.manifest,
              installedVersion: it?.version,
            ),
          DockLimitsCard(manifest: widget.manifest),
          if (it?.runStats case final stats?)
            DockActivityCard(stats: stats, fuelLimit: it!.fuelLimit),
          if (_hasHooks) DockHooksCard(moduleId: widget.manifest.id),
          if (commands.isNotEmpty)
            DockCommandPanelGroup(moduleId: it!.id, extensionPoints: commands),
          if (it != null) _dataCard(it),
        ],
      ],
    );
  }

  Widget _dataCard(api.InstalledDockModule it) {
    final storage = it.storage;
    return SettingsSectionCard(
      title: 'Data',
      children: [
        if (widget.onClearStorage != null && storage != null)
          SettingsDetailRow(
            title: 'Stored data',
            detail:
                '${storage.entries} of ${storage.maxEntries} entries, '
                '${dockBytes(storage.bytes)} of ${dockBytes(storage.maxBytes)}',
            trailing: AppButton(
              label: 'Clear data',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              semanticLabel: 'Clear stored data',
              disabled: widget.busy || storage.entries == 0,
              onPressed: widget.onClearStorage,
            ),
          ),
        if (widget.onExport != null)
          SettingsDetailRow(
            title: 'Package file',
            detail: 'Saves it without its settings or data.',
            trailing: AppButton(
              label: 'Export',
              icon: AppIcons.download,
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              disabled: widget.busy,
              onPressed: widget.onExport,
            ),
          ),
      ],
    );
  }
}

/// What installing registers into this space's role editor (decision 0021's
/// "Dynamic permissions").
class _PermissionsCard extends StatelessWidget {
  const _PermissionsCard({required this.permissions});

  final List<api.DockPermission> permissions;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Permissions it adds',
    children: [
      if (permissions.isEmpty)
        const SettingsInfoLine('None.')
      else
        for (final p in permissions)
          SettingsDetailRow(title: p.name, detail: p.description),
    ],
  );
}
