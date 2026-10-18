// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shortcut table under the home: what it does, and the keys.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// Read from the shared table so a remap moves these with it.
const _shown = [
  AppAction.quickSwitch,
  AppAction.nextChannel,
  AppAction.previousChannel,
  AppAction.openSettings,
];

/// Rows are two equal halves meeting on the column's centre line, so the seam
/// between labels and keycaps sits under the heading above.
class HomeShortcuts extends StatelessWidget {
  const HomeShortcuts({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      children: [
        for (final action in _shown)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s8),
            child: _ShortcutRow(action: action, tokens: tokens),
          ),
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.action, required this.tokens});

  final AppAction action;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final keys = describeAppAction(action);
    if (keys.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      // Grows with the text so the label half keeps room at a large text scale.
      constraints: BoxConstraints(
        maxWidth: MediaQuery.textScalerOf(context).scale(360),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              action.label,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            // Keycaps shrink rather than cut in a narrow pane.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, key) in keys.indexed) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          '+',
                          style: AppText.micro.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    AppKbd(key),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
