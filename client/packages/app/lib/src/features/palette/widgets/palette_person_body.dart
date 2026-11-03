// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A person's row content: avatar with presence, highlighted name, Bot chip
/// and the optional reason they matched. Shared by the palette and the
/// member picker so both draw the same person.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/widgets/user_avatar.dart';
import 'command_palette_items.dart' show PaletteReason;
import 'palette_highlight.dart';

class PalettePersonBody extends StatelessWidget {
  const PalettePersonBody({
    super.key,
    required this.member,
    required this.label,
    required this.query,
    this.reason,
  });

  final api.UserProfile member;
  final String label;
  final String query;
  final PaletteReason? reason;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      spacing: AppSpacing.s12,
      children: [
        UserAvatar.known(
          userId: member.id,
          avatarUpdatedAt: member.avatarUpdatedAt,
          name: member.displayName,
          size: AppAvatarSize.s28,
          presence: true,
        ),
        // The name and badge take the slack, so the reason sits at the right edge.
        Expanded(
          child: Row(
            spacing: AppSpacing.s12,
            children: [
              Flexible(
                child: paletteHighlighted(
                  label,
                  query,
                  AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              if (member.isBot)
                const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot'),
            ],
          ),
        ),
        if (reason != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${reason!.label}: '),
                  ...paletteHighlightSpans(reason!.value, query),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
      ],
    );
  }
}
