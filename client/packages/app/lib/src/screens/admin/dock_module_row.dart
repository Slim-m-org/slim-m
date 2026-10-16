// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One module in the Modules list, official or community. Split out of
/// `dock_screen.dart` so the community sections can reuse it.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../routing/routes.dart';
import '../../widgets/settings_detail_row.dart';
import 'dock_install_consent.dart';

class DockModuleRow extends StatelessWidget {
  const DockModuleRow({
    super.key,
    required this.entry,
    required this.installed,
    this.source,
  });

  final api.DockIndexEntry entry;

  /// This space's own install record for [entry], or null when it has never
  /// been docked here.
  final api.InstalledDockModule? installed;

  /// The community source this row was listed under; null is the official one.
  final String? source;

  /// What this space has, against what the marketplace now offers.
  ///
  /// A version that differs is the whole update affordance on this screen:
  /// the row used to show the registry's version and the word "Installed"
  /// side by side, which reads as agreement even when they disagree.
  static AppBadge _stateBadge(
    api.DockIndexEntry entry,
    api.InstalledDockModule installed,
  ) {
    if (installed.version != entry.version) {
      return AppBadge(variant: AppBadgeVariant.warn, label: 'Update available');
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

  /// The Verified mark, then the install state, beside the name.
  Widget? _badges(api.InstalledDockModule? installed, bool blocked) {
    final state = blocked
        ? const AppBadge(variant: AppBadgeVariant.tag, label: 'Id taken')
        : installed == null
        ? null
        : _stateBadge(entry, installed);
    final verified = dockIsVerified(source);
    if (state == null && !verified) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (verified) const DockVerifiedBadge(),
        if (verified && state != null) const SizedBox(width: AppSpacing.s8),
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
