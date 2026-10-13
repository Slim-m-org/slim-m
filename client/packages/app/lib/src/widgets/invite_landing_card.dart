// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What someone holding an invite link sees before they have an account: the
/// Space's banner, name, blurb and head count.
///
/// One widget for the join sheet and the admin preview, so what an admin
/// previews is what a visitor gets. The banner is passed in because the two
/// fetch it differently: a visitor has no session, an admin does.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../format.dart';

/// Wide and short, so a phone photo still leaves the text above the fold.
const double kInviteBannerAspect = 3;

/// Large enough to read as the space's mark, small enough to leave the name its line.
const double kInviteIconSize = AppSizes.icon32 + AppSpacing.s8;

class InviteLandingCard extends StatelessWidget {
  const InviteLandingCard({
    super.key,
    required this.name,
    required this.memberCount,
    this.description = '',
    this.banner,
    this.icon,
    this.invitedBy,
    this.expiresAt,
    this.use24Hour = false,
  });

  final String name;
  final int memberCount;
  final String description;

  /// Drawn cropped to [kInviteBannerAspect]; null draws no banner at all.
  final Widget? banner;

  /// Drawn at [kInviteIconSize] beside the name; null leaves the name alone.
  final Widget? icon;
  final String? invitedBy;
  final int? expiresAt;
  final bool use24Hour;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final meta = [
      '$memberCount ${memberCount == 1 ? 'member' : 'members'}',
      if (expiresAt != null)
        'Invite expires ${formatDateTime(expiresAt!, use24Hour: use24Hour)}',
    ].join('  -  ');

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (banner != null)
              AspectRatio(
                aspectRatio: kInviteBannerAspect,
                child: ExcludeSemantics(child: banner),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (invitedBy != null) ...[
                    Text(
                      '$invitedBy invited you to',
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                  ],
                  Row(
                    children: [
                      if (icon != null) ...[
                        SizedBox.square(
                          dimension: kInviteIconSize,
                          child: icon,
                        ),
                        const SizedBox(width: AppSpacing.s12),
                      ],
                      Expanded(child: _title(tokens)),
                    ],
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s8),
                    Text(
                      description,
                      style: AppText.ui.copyWith(color: tokens.textPrimary),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s12),
                  Row(
                    children: [
                      Icon(
                        AppIcons.members,
                        size: AppSizes.icon16,
                        color: tokens.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.s8),
                      Expanded(
                        child: Text(
                          meta,
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _title(AppTokens tokens) => Semantics(
    header: true,
    child: Text(
      name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppText.heading.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.semi,
      ),
    ),
  );
}
