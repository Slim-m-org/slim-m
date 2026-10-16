// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permission switches a bot is created with or edited to, one per bit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import 'permission_row.dart';

/// A bit the viewer does not hold is dimmed and locked: nobody grants more
/// than they hold.
class BotPermissionToggles extends ConsumerWidget {
  const BotPermissionToggles({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(myPermissionsProvider);
    return Column(
      children: [
        for (final (bit, label) in Perm.editable)
          PermissionRow(
            label: label,
            dimmed: !mine.hasPermission(bit),
            control: AppToggle(
              value: value.hasPermission(bit),
              semanticLabel: label,
              onChanged: mine.hasPermission(bit)
                  ? (on) => onChanged(on ? (value | bit) : (value & ~bit))
                  : null,
            ),
          ),
      ],
    );
  }
}
