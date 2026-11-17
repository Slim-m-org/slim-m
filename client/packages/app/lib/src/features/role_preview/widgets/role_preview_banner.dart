// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fixed band over a role preview: which role, that nothing here can be changed, and Exit.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class RolePreviewBanner extends StatelessWidget {
  const RolePreviewBanner({
    super.key,
    required this.roleName,
    required this.onExit,
  });

  final String roleName;
  final VoidCallback onExit;

  static const exitKey = Key('role-preview-exit');

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s12,
        AppSpacing.s8,
        AppSpacing.s12,
        AppSpacing.s8,
      ),
      child: AppCallout(
        key: const Key('role-preview-banner'),
        tone: AppCalloutTone.accent,
        icon: AppIcons.preview,
        centred: true,
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Viewing as $roleName',
                      style: const TextStyle(fontWeight: AppWeights.semi),
                    ),
                    TextSpan(
                      text: ' - read-only',
                      style: TextStyle(color: tokens.textSecondary),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.s12),
            AppButton(
              key: exitKey,
              label: 'Exit',
              size: AppButtonSize.sm,
              onPressed: onExit,
            ),
          ],
        ),
      ),
    );
  }
}
