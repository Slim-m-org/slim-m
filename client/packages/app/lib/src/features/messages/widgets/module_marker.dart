// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host-written line under a message a module posted.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// Drawn from the message's own `via_module`, never from anything the module
/// wrote, and on every row of a run so a grouped continuation still carries it.
class ModuleMarker extends StatelessWidget {
  const ModuleMarker({super.key, required this.module});

  final api.ViaModule module;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = module.background
        ? '${module.name} module'
        : 'via ${module.name}';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.dock, size: 14, color: tokens.textSecondary),
          const SizedBox(width: AppSpacing.s4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
