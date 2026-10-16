// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bordered card the permissions grid sits in, matching a settings
/// section's flush card: the toolbar, the legend, then the grid itself.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_permissions_grid_rows.dart';
import 'channel_permissions_toolbar.dart';

class PermissionsCard extends StatelessWidget {
  const PermissionsCard({
    super.key,
    required this.filter,
    required this.onFilterChanged,
    required this.onAdd,
    required this.shrinkWrap,
    required this.grid,
  });

  final TextEditingController filter;
  final VoidCallback onFilterChanged;
  final VoidCallback onAdd;

  /// Lay out at full height for a host that scrolls, else fill the space given.
  final bool shrinkWrap;
  final Widget grid;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card - 1),
        child: Column(
          mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PermissionsToolbar(
              filter: filter,
              onFilterChanged: onFilterChanged,
              onAdd: onAdd,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.s16,
                0,
                AppSpacing.s16,
                AppSpacing.s12,
              ),
              child: Legend(),
            ),
            if (shrinkWrap) grid else Expanded(child: grid),
          ],
        ),
      ),
    );
  }
}
