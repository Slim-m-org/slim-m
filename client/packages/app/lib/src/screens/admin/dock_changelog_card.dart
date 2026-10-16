// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's release notes on its screen.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_section_header.dart';

/// What changed: the newest entry before install, every entry the space is
/// missing once installed. Draws nothing when there is nothing to say.
/// Entries shown before the rest collapse into a count.
const dockChangelogCap = 5;

class DockChangelogCard extends StatelessWidget {
  const DockChangelogCard({
    super.key,
    required this.manifest,
    required this.installedVersion,
  });

  final api.DockManifest manifest;
  final String? installedVersion;

  @override
  Widget build(BuildContext context) {
    final all = manifest.changesSince(installedVersion);
    if (all.isEmpty) return const SizedBox.shrink();
    final entries = all.take(dockChangelogCap).toList();
    final cut = all.length - entries.length;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s16),
      child: SettingsSectionCard(
        title: "What's new",
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s8,
                vertical: AppSpacing.s4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'v${entry.version}',
                    style: AppText.body.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.medium,
                    ),
                  ),
                  for (final change in entry.changes)
                    Text(
                      change,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          if (cut > 0)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s8,
                vertical: AppSpacing.s4,
              ),
              child: Text(
                cut == 1
                    ? 'and 1 earlier version'
                    : 'and $cut earlier versions',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
