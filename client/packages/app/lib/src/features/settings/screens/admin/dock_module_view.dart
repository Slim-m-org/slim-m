// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's page: a health banner, then Overview, Access and Settings tabs.
/// Overview says what the module is and holds its actions; Access holds every
/// grant and carries the Save for them; Settings holds what the module
/// configures and reports.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_save_bar.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_tab_strip.dart';
import 'dock_activity_card.dart';
import 'dock_call_audio_card.dart';
import 'dock_changelog_card.dart';
import 'dock_command_panel_group.dart';
import 'dock_health_card.dart';
import 'dock_hooks_card.dart';
import 'dock_host_access_card.dart';
import 'dock_install_consent.dart';
import 'dock_limits_card.dart';
import 'dock_module_actions.dart';
import 'dock_role_access_card.dart';
import 'dock_schedule_card.dart';
import 'dock_settings_card.dart';
import 'dock_what_it_adds.dart';

enum DockModuleTab { overview, access, settings }

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
/// No title row of its own: the app bar already names the module.
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
    required this.tab,
    required this.onTab,
    required this.approvedHostCapabilities,
    required this.onToggleHostCapability,
    required this.onDiscardAccess,
    this.reapprove = const [],
    this.localNetworkApproved = false,
    this.onLocalNetworkChanged,
    this.scheduleChannels = const [],
    this.onScheduleChannel,
    this.onClearStorage,
    this.onExport,
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

  /// The tab showing, and the way to change it.
  final DockModuleTab tab;
  final ValueChanged<DockModuleTab> onTab;

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

  /// Empties the module's stored data; offered when it keeps some.
  final VoidCallback? onClearStorage;

  /// Saves the module as a package file.
  final VoidCallback? onExport;
  final void Function(String capability, bool approved) onToggleHostCapability;

  /// Puts the switches back to what this space approved.
  final VoidCallback onDiscardAccess;
  final bool busy;
  final String? error;
  final VoidCallback onErrorDismiss;
  final VoidCallback onInstall;
  final ValueChanged<bool> onSetEnabled;
  final VoidCallback onUninstall;

  List<api.DockExtensionPoint> get _commands {
    final it = installed;
    if (it == null || !it.enabled) return const [];
    return it.extensionPoints
        .where((ep) => ep.kind == 'command')
        .toList(growable: false);
  }

  bool get _hasHooks =>
      installed != null &&
      (manifest.interceptors.isNotEmpty || manifest.permissionHooks.isNotEmpty);

  bool get _hasSettingsTab =>
      installed != null &&
      (installed!.declaresSettings ||
          _hasHooks ||
          _commands.isNotEmpty ||
          installed!.runStats != null);

  /// How many switches differ from what this space approved at its last
  /// install, which is when a Save is needed for them to take effect.
  int get _accessChanges {
    final it = installed;
    if (it == null) return 0;
    final current = it.approvedHostCapabilities.toSet();
    return current.difference(approvedHostCapabilities).length +
        approvedHostCapabilities.difference(current).length +
        (it.localNetworkApproved != localNetworkApproved ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      (DockModuleTab.overview, 'Overview'),
      (DockModuleTab.access, 'Access'),
      if (_hasSettingsTab) (DockModuleTab.settings, 'Settings'),
    ];
    final shown = tabs.any((t) => t.$1 == tab) ? tab : DockModuleTab.overview;
    final primary = DockPrimaryAction(
      manifest: manifest,
      installed: installed,
      busy: busy,
      onPressed: onInstall,
    );
    final changes = shown == DockModuleTab.access ? _accessChanges : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (installed case final it? when dockHasHealthNews(it))
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              AppSpacing.s16,
              AppSpacing.s16,
              0,
            ),
            child: DockHealthCard(
              installed: it,
              onTurnOn: () => onSetEnabled(true),
              enabled: !busy,
            ),
          ),
        const SizedBox(height: AppSpacing.s8),
        SettingsTabStrip<DockModuleTab>(
          tabs: tabs,
          selected: shown,
          onSelected: onTab,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.s16),
            children: [
              if (error != null) ...[
                AppErrorState(message: error!, onDismiss: onErrorDismiss),
                const SizedBox(height: AppSpacing.s12),
              ],
              ...switch (shown) {
                DockModuleTab.overview => _overview(context),
                DockModuleTab.access => _access(),
                DockModuleTab.settings => _settings(),
              },
            ],
          ),
        ),
        if (primary.visible)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            child: primary,
          )
        else if (changes > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            child: SettingsSaveBar(
              changeCount: changes,
              saving: busy,
              onDiscard: onDiscardAccess,
              onSave: onInstall,
            ),
          ),
      ],
    );
  }

  List<Widget> _overview(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return [
      Row(
        children: [
          Flexible(
            child: Text(
              manifest.author == null
                  ? 'v${manifest.version}'
                  : 'v${manifest.version} · ${manifest.author}',
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: tokens.textSecondary,
                fontFamily: AppFonts.mono,
              ),
            ),
          ),
          if (verified) ...[
            const SizedBox(width: AppSpacing.s8),
            const DockVerifiedBadge(),
          ],
        ],
      ),
      if (sourceRepo != null) ...[
        const SizedBox(height: AppSpacing.s8),
        Align(
          alignment: Alignment.centerLeft,
          child: AppBadge(
            variant: AppBadgeVariant.warn,
            label: switch (sourceRepo) {
              'local/dev' => 'Not verified, local',
              api.kFileDockRepo => 'Not verified, from a file',
              _ => 'Community source: $sourceRepo',
            },
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.s12),
      Text(
        manifest.summary,
        style: AppText.body.copyWith(color: tokens.textPrimary),
      ),
      _PermissionsCard(permissions: manifest.permissions),
      if (manifest.extensionPoints.any((ep) => ep.kind != 'command'))
        DockWhatItAddsCard(extensionPoints: manifest.extensionPoints),
      DockChangelogCard(
        manifest: manifest,
        installedVersion: installed?.version,
      ),
      DockModuleActions(
        manifest: manifest,
        installed: installed,
        busy: busy,
        onSetEnabled: onSetEnabled,
        onUninstall: onUninstall,
        onExport: onExport,
        onClearStorage:
            installed != null &&
                installed!.approvedHostCapabilities.contains('kv.store')
            ? onClearStorage
            : null,
      ),
    ];
  }

  List<Widget> _access() {
    final it = installed;
    return [
      if (it != null) DockRoleAccessCard(manifest: manifest),
      if (grantableHostCapabilities(manifest.capabilities).isNotEmpty)
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
      if (it != null &&
          it.approvedHostCapabilities.contains('schedule') &&
          onScheduleChannel != null)
        DockScheduleCard(
          schedules: it.schedules,
          channels: scheduleChannels,
          channelId: it.scheduleChannelId,
          onChannel: onScheduleChannel!,
          enabled: !busy,
        ),
      if (it != null && it.approvedHostCapabilities.contains('call.audio'))
        DockCallAudioCard(
          moduleId: it.id,
          moduleName: manifest.name,
          enabled: !busy,
        ),
      DockLimitsCard(manifest: manifest),
    ];
  }

  List<Widget> _settings() {
    final it = installed!;
    return [
      if (it.declaresSettings) DockSettingsCard(moduleId: it.id),
      if (_hasHooks) DockHooksCard(moduleId: manifest.id),
      if (_commands.isNotEmpty)
        DockCommandPanelGroup(moduleId: it.id, extensionPoints: _commands),
      if (it.runStats != null)
        DockActivityCard(stats: it.runStats!, fuelLimit: it.fuelLimit),
    ];
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
    return SettingsSectionCard(
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
}
