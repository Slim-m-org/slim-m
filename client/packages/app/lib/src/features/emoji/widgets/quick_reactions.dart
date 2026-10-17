// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The five reactions a message menu offers without opening the picker.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../action_labels.dart';

import '../../../widgets/control_swatch_row.dart';

/// One quick reaction: [token] is exactly what the picker would have produced
/// for it, so a quick pick and a picked one are the same reaction on the wire.
class QuickReaction {
  const QuickReaction(this.token, this.label);

  final String token;
  final String label;
}

/// A fixed default; a per-person set needs somewhere to store usage and is its own decision.
const kQuickReactions = [
  QuickReaction('\u{1F44D}', 'Thumbs up'),
  QuickReaction('\u{2764}\u{FE0F}', 'Heart'),
  QuickReaction('\u{1F602}', 'Laughing'),
  QuickReaction('\u{1F389}', 'Celebrate'),
  QuickReaction('\u{1F440}', 'Eyes'),
];

/// The quick row a message menu opens with: one tile per [kQuickReactions]
/// entry and a trailing "+" that opens the full picker.
///
/// [reacted] marks the tiles the viewer has already used; picking one again
/// takes it back, which is the toggle the chip under the message already has.
class QuickReactionRow extends StatelessWidget {
  const QuickReactionRow({
    super.key,
    required this.reacted,
    required this.onPick,
    required this.onMore,
    required this.close,
  });

  final Set<String> reacted;
  final ValueChanged<String> onPick;
  final VoidCallback onMore;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ControlSwatchRow(
      close: close,
      swatches: [
        for (final quick in kQuickReactions)
          ControlSwatch(
            label: reacted.contains(quick.token)
                ? '${quick.label}, selected'
                : quick.label,
            selected: reacted.contains(quick.token),
            onSelected: () => onPick(quick.token),
            mark: Text(quick.token, style: AppText.heading.copyWith(height: 1)),
          ),
        ControlSwatch(
          label: ActionLabels.addReaction,
          selected: false,
          onSelected: onMore,
          mark: Icon(
            AppIcons.add,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
        ),
      ],
    );
  }
}
