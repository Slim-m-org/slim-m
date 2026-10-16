// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's release notes on its screen.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_section_header.dart';

/// What changed: the newest entry before install, every entry the space is
/// missing once installed. Draws nothing when there is nothing to say.
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
    final entries = manifest.changesSince(installedVersion);
    if (entries.isEmpty) return const SizedBox.shrink();
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
        ],
      ),
    );
  }
}
