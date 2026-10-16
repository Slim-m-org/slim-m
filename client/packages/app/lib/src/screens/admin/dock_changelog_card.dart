// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's release notes on its screen.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import '../../widgets/settings_card_note.dart';
import '../../widgets/settings_detail_row.dart';
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
    return SettingsSectionCard(
      flush: true,
      title: "What's new",
      children: [
        for (final entry in entries)
          SettingsDetailRow(
            title: 'v${entry.version}',
            detail: entry.changes.join('\n'),
          ),
        if (cut > 0)
          SettingsCardNote(
            cut == 1 ? 'and 1 earlier version' : 'and $cut earlier versions',
          ),
      ],
    );
  }
}
