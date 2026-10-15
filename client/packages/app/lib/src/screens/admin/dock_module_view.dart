// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The read side of [DockManifestView]: a manifest's own summary, the
/// permissions it will add, the capabilities it asks for, and the
/// install/enable-disable/uninstall controls - split out of
/// `dock_module_sheet.dart` purely for that file's line budget, the same
/// reasoning `analytics_charts.dart` split off `analytics_screen.dart` on.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';
import 'dock_command_panel_group.dart';
import 'dock_host_access_card.dart';
import 'dock_install_consent.dart';
import 'dock_limits_card.dart';
import 'dock_schedule_card.dart';
import 'dock_what_it_adds.dart';

/// A module's manifest, plus the lifecycle action appropriate to
/// [installed]'s state: install when null, otherwise an enable/disable
/// toggle and an uninstall button, with an update above them when this space
/// is on an older version than the marketplace now offers.
///
/// An update is a re-install at the new version, with no separate route. The
/// server upserts the row, leaves `enabled` alone, and only drops permission
/// rows the new manifest stops declaring, so grants for surviving keys and the
/// enabled state both come through untouched. See `store/modules.rs`.
///
/// No title row of its own. This was a sheet once and carried a header with
/// the module's name and a Close button; as a routed screen the app bar
/// already names the module and already has a back arrow, so the header was
/// the module's name printed twice under two ways out.
class DockManifestView extends StatelessWidget {
  const DockManifestView({
    super.key,
    required this.manifest,
    required this.installed,
    required this.busy,
    required this.error,
    required this.onErrorDismiss,
    required this.onInstall,
    required this.onSetEnabled,
    required this.onUninstall,
    required this.onChooseAccess,
    required this.approvedHostCapabilities,
    required this.onToggleHostCapability,
    this.reapprove = const [],
    this.localNetworkApproved = false,
    this.onLocalNetworkChanged,
    this.scheduleChannels = const [],
    this.onScheduleChannel,
    this.sourceRepo,
    this.verified = false,
  });

  final api.DockManifest manifest;

  /// The community source's `owner/repo` this module comes from, or null for
  /// the official source. Shown before anything is installed.
  final String? sourceRepo;

  /// Listed in the official registry, which slim-m reviews.
  final bool verified;
  final api.InstalledDockModule? installed;

  /// The host capabilities currently switched on, applied on the next install
  /// or save.
  final Set<String> approvedHostCapabilities;

  /// Capabilities this update is a new build of: each switch is off until the
  /// admin turns it on again.
  final List<String> reapprove;

  /// The second, separate yes for net.fetch to reach the local network.
  final bool localNetworkApproved;
  final ValueChanged<bool>? onLocalNetworkChanged;

  /// Text channels a schedule can post in, and the callback for choosing one.
  final List<api.Channel> scheduleChannels;
  final ValueChanged<String?>? onScheduleChannel;
  final void Function(String capability, bool approved) onToggleHostCapability;
  final bool busy;
  final String? error;
  final VoidCallback onErrorDismiss;
  final VoidCallback onInstall;
  final ValueChanged<bool> onSetEnabled;
  final VoidCallback onUninstall;

  /// Opens the who-can-use-this sheet. Present whether or not the module is
  /// installed; the action card only offers it once it is.
  final VoidCallback onChooseAccess;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // No title row: the app bar already names the module; see this class's doc.
        Text(
          manifest.author == null
              ? 'v${manifest.version}'
              : 'v${manifest.version} · ${manifest.author}',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        if (verified) ...[
          const SizedBox(height: AppSpacing.s8),
          const Align(
            alignment: Alignment.centerLeft,
            child: DockVerifiedBadge(),
          ),
        ],
        if (sourceRepo != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppBadge(
            variant: AppBadgeVariant.warn,
            label: 'Community source: $sourceRepo',
          ),
        ],
        const SizedBox(height: AppSpacing.s12),
        Text(
          manifest.summary,
          style: AppText.body.copyWith(color: tokens.textPrimary),
        ),
        const SizedBox(height: AppSpacing.s16),
        _PermissionsCard(permissions: manifest.permissions),
        if (manifest.extensionPoints.any((ep) => ep.kind != 'command')) ...[
          const SizedBox(height: AppSpacing.s16),
          DockWhatItAddsCard(extensionPoints: manifest.extensionPoints),
        ],
        const SizedBox(height: AppSpacing.s16),
        DockLimitsCard(manifest: manifest),
        if (grantableHostCapabilities(manifest.capabilities).isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s16),
          DockHostAccessCard(
            manifest: manifest,
            approved: approvedHostCapabilities,
            onChanged: onToggleHostCapability,
            moduleName: manifest.name,
            localNetworkApproved: localNetworkApproved,
            onLocalNetworkChanged: onLocalNetworkChanged,
            reapprove: reapprove,
            enabled: !busy,
          ),
        ],
        if (installed != null &&
            installed!.approvedHostCapabilities.contains('schedule') &&
            onScheduleChannel != null) ...[
          const SizedBox(height: AppSpacing.s16),
          DockScheduleCard(
            schedules: installed!.schedules,
            channels: scheduleChannels,
            channelId: installed!.scheduleChannelId,
            onChannel: onScheduleChannel!,
            enabled: !busy,
          ),
        ],
        const SizedBox(height: AppSpacing.s16),
        _ActionsCard(
          manifest: manifest,
          installed: installed,
          hostAccessChanged: _hostAccessChanged(),
          busy: busy,
          onInstall: onInstall,
          onSetEnabled: onSetEnabled,
          onUninstall: onUninstall,
          onChooseAccess: onChooseAccess,
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: error!, onDismiss: onErrorDismiss),
        ],
        if (_runnableCommands(installed) case final commands
            when commands.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s16),
          DockCommandPanelGroup(
            moduleId: installed!.id,
            extensionPoints: commands,
          ),
        ],
      ],
    );
  }

  /// Whether the switches differ from what this space approved at its last
  /// install, which is when a Save is needed for them to take effect.
  bool _hostAccessChanged() {
    final current = installed?.approvedHostCapabilities.toSet() ?? const {};
    return installed != null &&
        (current.length != approvedHostCapabilities.length ||
            !current.containsAll(approvedHostCapabilities) ||
            installed!.localNetworkApproved != localNetworkApproved);
  }

  /// Every `command` extension point [installed] declares, or none at all
  /// while the module is not installed or is disabled - a command only
  /// reaches the host under those two conditions (`http::module_commands`),
  /// so this panel offers nothing a Run could not possibly answer.
  static List<api.DockExtensionPoint> _runnableCommands(
    api.InstalledDockModule? installed,
  ) {
    if (installed == null || !installed.enabled) return const [];
    return installed.extensionPoints
        .where((ep) => ep.kind == 'command')
        .toList(growable: false);
  }
}

/// What installing registers into this space's role editor, shown before
/// install rather than discovered afterward - see decision 0021's "Dynamic
/// permissions".
class _PermissionsCard extends StatelessWidget {
  const _PermissionsCard({required this.permissions});

  final List<api.DockPermission> permissions;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (permissions.isEmpty) {
      return SettingsSectionCard(
        title: 'Permissions this will add',
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: Text(
              'None. This module adds no grantable permission.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      );
    }
    return SettingsSectionCard(
      title: 'Permissions this will add',
      children: [
        for (final p in permissions)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s8,
              vertical: AppSpacing.s4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name,
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
                Text(
                  p.description,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({
    required this.manifest,
    required this.installed,
    required this.hostAccessChanged,
    required this.busy,
    required this.onInstall,
    required this.onSetEnabled,
    required this.onUninstall,
    required this.onChooseAccess,
  });

  final api.DockManifest manifest;
  final api.InstalledDockModule? installed;
  final bool hostAccessChanged;
  final bool busy;
  final VoidCallback onInstall;
  final ValueChanged<bool> onSetEnabled;
  final VoidCallback onUninstall;

  /// Opens the who-can-use-this sheet. Present whether or not the module is
  /// installed; the action card only offers it once it is.
  final VoidCallback onChooseAccess;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final installed = this.installed;
    if (installed == null) {
      return AppButton(
        label: busy ? 'Installing...' : 'Install v${manifest.version}',
        variant: AppButtonVariant.primary,
        full: true,
        disabled: busy,
        onPressed: onInstall,
      );
    }
    final outdated = installed.version != manifest.version;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (outdated) ...[
          // Re-installing at the new version is the update; see the class doc.
          AppButton(
            label: busy ? 'Updating...' : 'Update to v${manifest.version}',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: busy,
            onPressed: onInstall,
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            'This space is on v${installed.version}. Updating keeps who can '
            'use it, and whether it is on.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        if (hostAccessChanged && !outdated) ...[
          AppButton(
            label: busy ? 'Saving...' : 'Save access',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: busy,
            onPressed: onInstall,
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        SettingsSectionCard(
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
          ],
        ),
        if (manifest.permissions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s12),
          // Installed grants nothing, so this is the step to it appearing at all.
          AppButton(
            label: 'Choose who can use this',
            variant: AppButtonVariant.secondary,
            full: true,
            disabled: busy,
            onPressed: onChooseAccess,
          ),
        ],
        const SizedBox(height: AppSpacing.s12),
        AppButton(
          label: 'Uninstall',
          variant: AppButtonVariant.danger,
          full: true,
          disabled: busy,
          onPressed: onUninstall,
        ),
      ],
    );
  }
}
