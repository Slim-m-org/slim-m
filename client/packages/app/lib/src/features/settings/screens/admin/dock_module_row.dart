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
  /// The version is not on the row: it lives on the module's page.
  final bool showInstalledState;

  /// Update when this space is behind its source, else Installed, or Off on
  /// the Installed list where Installed would label every row.
  AppBadge? _stateBadge(api.InstalledDockModule? installed) {
    if (entry.shadowed) {
      return const AppBadge(variant: AppBadgeVariant.tag, label: 'Id taken');
    }
    if (installed == null) return null;
    if (installed.version != entry.version) {
      return const AppBadge(variant: AppBadgeVariant.warn, label: 'Update');
    }
    if (!installed.enabled) {
      return const AppBadge(variant: AppBadgeVariant.tag, label: 'Off');
    }
    return showInstalledState
        ? const AppBadge(variant: AppBadgeVariant.role, label: 'Installed')
        : null;
  }

  /// The verified mark, then the install state, beside the name.
  Widget _badges(api.InstalledDockModule? installed) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: AppSpacing.s8,
    children: [
      if (dockIsVerified(source)) const DockVerifiedBadge(),
      ?_stateBadge(installed),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final installed = this.installed;
    final blocked = entry.shadowed;
    return SettingsDetailRow(
      icon: AppIcons.dock,
      title: entry.name,
      badge: _badges(installed),
      detailMaxLines: 1,
      detail: blocked
          ? 'Another source already has a module with this id.'
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
