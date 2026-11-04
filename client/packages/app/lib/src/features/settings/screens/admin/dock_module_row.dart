// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One module in the Modules list, official or community. Split out of
/// `dock_screen.dart` so the community sections can reuse it.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../routing/routes.dart';
import '../../widgets/settings_detail_row.dart';
import 'dock_install_consent.dart';

class DockModuleRow extends StatelessWidget {
  const DockModuleRow({
    super.key,
    required this.entry,
    required this.installed,
    this.source,
    this.showInstalledState = true,
  });

  final api.DockIndexEntry entry;

  /// This space's own install record for [entry], or null when it has never
  /// been docked here.
  final api.InstalledDockModule? installed;

  /// The community source this row was listed under; null is the official one.
  final String? source;

  /// False on the Installed list, where "Installed" would label every row.
  final bool showInstalledState;

  /// What this space has, against what the marketplace now offers.
  ///
  /// A version that differs is the whole update affordance on this screen:
  /// the row used to show the registry's version and the word "Installed"
  /// side by side, which reads as agreement even when they disagree.
  AppBadge? _stateBadge(
    api.DockIndexEntry entry,
    api.InstalledDockModule installed,
  ) {
    if (installed.version != entry.version) {
      return const AppBadge(variant: AppBadgeVariant.warn, label: 'Update');
    }
    if (!showInstalledState) {
      return installed.enabled
          ? null
          : const AppBadge(variant: AppBadgeVariant.tag, label: 'Off');
    }
    return AppBadge(
      variant: AppBadgeVariant.role,
      label: installed.enabled ? 'Installed' : 'Installed · Off',
    );
  }

  /// Both versions when they differ, so the badge never has to carry one.
  static String _versionLine(
    api.DockIndexEntry entry,
    api.InstalledDockModule? installed,
  ) => installed == null || installed.version == entry.version
      ? 'v${entry.version}'
      : 'Installed v${installed.version}, latest v${entry.version}';

  AppBadge? _stateOrBlockedBadge(
    api.InstalledDockModule? installed,
    bool blocked,
  ) {
    if (blocked) {
      return const AppBadge(variant: AppBadgeVariant.tag, label: 'Id taken');
    }
    return installed == null ? null : _stateBadge(entry, installed);
  }

  /// The trust badge, then the install state, beside the name.
  Widget? _badges(api.InstalledDockModule? installed, bool blocked) {
    final state = _stateOrBlockedBadge(installed, blocked);
    final verified = dockIsVerified(source);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        if (verified)
          const DockVerifiedBadge()
        else
          const AppBadge(variant: AppBadgeVariant.tag, label: 'Not verified'),
        ?state,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final installed = this.installed;
    final blocked = entry.shadowed;
    return SettingsDetailRow(
      icon: AppIcons.dock,
      title: entry.name,
      badge: _badges(installed, blocked),
      meta: _versionLine(entry, installed),
      detail: blocked
          ? 'Another source already provides a module with this id, so it '
                'cannot be installed from here.'
          : entry.summary,
      onTap: blocked
          ? null
          : () =>
                context.push(Routes.adminDockModule(entry.id, source: source)),
      onTapSemanticLabel: 'View ${entry.name}',
      // Decorative: the row itself is the control, so this points the way without being a second, smaller target.
      trailing: blocked
          ? null
          : ExcludeSemantics(
              child: Icon(AppIcons.chevronRight, color: tokens.textSecondary),
            ),
    );
  }
}
