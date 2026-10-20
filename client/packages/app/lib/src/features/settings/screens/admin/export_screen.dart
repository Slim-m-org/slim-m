// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Export this Space: an administrator's copy of the community in the format
/// `docs/data-export-format.md` documents.
///
/// ADMINISTRATOR, not MANAGE_SERVER, matching `POST /exports/space`: the
/// archive reads every channel, which MANAGE_SERVER does not allow (decision
/// 0084). Without the bit the pane says why rather than going blank, the same
/// rule [AccountRecoveryPane] follows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../../widgets/data_export_card.dart';
import '../../widgets/data_export_copy.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';

class ExportScreen extends StatelessWidget {
  const ExportScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Export',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: ExportPane(),
  );
}

class ExportPane extends ConsumerWidget {
  const ExportPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref
        .watch(myPermissionsProvider)
        .hasPermission(Perm.administrator);
    if (!allowed) {
      return const SettingsSectionCard(
        children: [
          SettingsEmptyState(
            icon: AppIcons.shield,
            title: 'Exporting the Space needs the administrator permission.',
            detail: 'It reads every channel.',
          ),
        ],
      );
    }
    return const DataExportCard(copy: DataExportCopy.space);
  }
}
