// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip above the permissions grid: a filter over permission names, the
/// way the role Permissions tab filters, plus a labelled control to add a
/// role or member column. Split out of `channel_permissions_grid.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class PermissionsToolbar extends StatelessWidget {
  const PermissionsToolbar({
    super.key,
    required this.filter,
    required this.onFilterChanged,
    required this.onAdd,
  });

  final TextEditingController filter;
  final VoidCallback onFilterChanged;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        AppSpacing.s8,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final compact = box.maxWidth < kCompactWidth;
          return Row(
            children: [
              Expanded(
                child: AppInput(
                  controller: filter,
                  placeholder: 'Filter permissions',
                  icon: const Icon(AppIcons.search),
                  semanticLabel: 'Filter permissions',
                  onChanged: (_) => onFilterChanged(),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              if (compact)
                AppIconButton(
                  icon: AppIcons.add,
                  semanticLabel: 'Add a role or member',
                  onPressed: onAdd,
                )
              else
                AppButton(
                  label: 'Add role or member',
                  icon: AppIcons.add,
                  onPressed: onAdd,
                ),
            ],
          );
        },
      ),
    );
  }
}
