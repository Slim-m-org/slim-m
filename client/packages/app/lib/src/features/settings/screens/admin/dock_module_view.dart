// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's page, one list for an admin rather than a developer: what it is,
/// whether it runs and who may use it, its own settings, what it may do, then
/// a folded Details section and Uninstall at the foot.
///
/// One page, not tabs: with the developer detail folded away the page fits a
/// phone in a scroll or two, and tabs hid who may use it a layer down.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_save_bar.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_call_audio_card.dart';
import 'dock_changelog_card.dart';
import 'dock_display_card.dart';
import 'dock_health_card.dart';
import 'dock_host_access_card.dart';
import 'dock_install_consent.dart';
import 'dock_limits_card.dart';
import 'dock_module_actions.dart';
import 'dock_module_details.dart';
import 'dock_schedule_card.dart';
import 'dock_settings_card.dart';

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
    this.rolesOpen = false,
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

  /// Opens the role switches, right after a first install.
  final bool rolesOpen;

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

  bool get _updatePending =>
      installed != null && installed!.version != manifest.version;

  @override
  Widget build(BuildContext context) {
    final primary = DockPrimaryAction(
      manifest: manifest,
      installed: installed,
      busy: busy,
      onPressed: onInstall,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.s16),
            children: [
              if (installed case final it? when dockHasHealthNews(it)) ...[
                DockHealthCard(
                  installed: it,
                  onTurnOn: () => onSetEnabled(true),
                  enabled: !busy,
                ),
                const SizedBox(height: AppSpacing.s12),
              ],
              if (error != null) ...[
                AppErrorState(message: error!, onDismiss: onErrorDismiss),
                const SizedBox(height: AppSpacing.s12),
              ],
              _DockModuleHeader(
                manifest: manifest,
                sourceRepo: sourceRepo,
                verified: verified,
              ),
              if (installed case final it?) ...[
                DockModuleControls(
                  manifest: manifest,
                  installed: it,
                  busy: busy,
                  onSetEnabled: onSetEnabled,
                  rolesOpen: rolesOpen,
                ),
                if (it.declaresSettings) DockSettingsCard(moduleId: it.id),
                DockDisplayCard(installed: it),
              ],
              ..._access(),
              if (_updatePending)
                DockChangelogCard(
                  manifest: manifest,
                  installedVersion: installed!.version,
                ),
              DockModuleDetails(
                manifest: manifest,
                installed: installed,
                busy: busy,
                showChangelog: !_updatePending,
                onExport: onExport,
                onClearStorage:
                    installed != null &&
                        installed!.approvedHostCapabilities.contains('kv.store')
                    ? onClearStorage
                    : null,
              ),
              if (installed != null)
                DockUninstallRow(busy: busy, onUninstall: onUninstall),
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
          ),
      ],
    );
  }

  /// What it may do, with the Save for those switches right under them.
  List<Widget> _access() {
    final it = installed;
    final changes = _accessChanges;
    final asks = grantableHostCapabilities(manifest.capabilities).isNotEmpty;
    return [
      if (asks)
        DockHostAccessCard(
          manifest: manifest,
          approved: approvedHostCapabilities,
          onChanged: onToggleHostCapability,
          moduleName: manifest.name,
          localNetworkApproved: localNetworkApproved,
          onLocalNetworkChanged: onLocalNetworkChanged,
          reapprove: reapprove,
          enabled: !busy,
        )
      else
        const SettingsSectionCard(
          title: 'Access',
          children: [SettingsInfoLine(dockNoAccessNote)],
        ),
      if (changes > 0 && !_updatePending) ...[
        const SizedBox(height: AppSpacing.s12),
        SettingsSaveBar(
          changeCount: changes,
          saving: busy,
          onDiscard: onDiscardAccess,
          onSave: onInstall,
        ),
      ],
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
    ];
  }
}

/// The summary, then the version, author and trust marks under it. The app
/// bar already names the module.
class _DockModuleHeader extends StatelessWidget {
  const _DockModuleHeader({
    required this.manifest,
    required this.sourceRepo,
    required this.verified,
  });

  final api.DockManifest manifest;
  final String? sourceRepo;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          manifest.summary,
          style: AppText.body.copyWith(color: tokens.textPrimary),
        ),
        const SizedBox(height: AppSpacing.s8),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (verified) const DockVerifiedBadge(),
            Text(
              manifest.author == null
                  ? 'v${manifest.version}'
                  : 'v${manifest.version} · ${manifest.author}',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            if (sourceRepo case final repo?)
              AppBadge(
                variant: AppBadgeVariant.warn,
                label: switch (repo) {
                  'local/dev' => 'Not verified, local',
                  api.kFileDockRepo => 'Not verified, from a file',
                  _ => 'Community source: $repo',
                },
              ),
          ],
        ),
      ],
    );
  }
}
