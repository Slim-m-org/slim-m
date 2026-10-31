// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Modules list's card for modules that came from a package file: the ones
/// installed that way, and the way to add another.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_module_row.dart';

class DockFileSection extends StatelessWidget {
  const DockFileSection({
    super.key,
    required this.catalog,
    required this.onInstall,
  });

  final DockCatalog catalog;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final fromFiles = [
      for (final m in catalog.installed)
        if (m.sourceRepo == api.kFileDockRepo) m,
    ];
    return SettingsSectionCard(
      title: 'Module files',
      description: 'Not verified, so review what each module can do.',
      children: [
        for (final m in fromFiles)
          DockModuleRow(
            entry: api.DockIndexEntry(
              id: m.id,
              name: m.name,
              version: m.version,
              summary: 'Installed from a file.',
            ),
            installed: m,
            source: api.kFileDockSource,
          ),
        SettingsActionRow(
          message: 'A module someone gave you as a file.',
          action: AppButton(
            label: 'Install from a file',
            icon: AppIcons.fileArchive,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: onInstall,
          ),
        ),
      ],
    );
  }
}
