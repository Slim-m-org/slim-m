// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a server has waiting: a mention count, or a dot for plain unread.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/account_unread.dart';

class AccountUnreadBadge extends StatelessWidget {
  const AccountUnreadBadge({super.key, required this.unread});

  final AccountUnread unread;

  static const Key countKey = Key('account_unread_count');
  static const Key dotKey = Key('account_unread_dot');

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (unread.mentions > 0) {
      final count = unread.mentions > 99 ? '99+' : '${unread.mentions}';
      return Semantics(
        label: '${unread.mentions} mentions',
        excludeSemantics: true,
        child: Container(
          key: countKey,
          constraints: const BoxConstraints(minWidth: AppSizes.icon16),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          decoration: BoxDecoration(
            color: tokens.accentFill,
            borderRadius: BorderRadius.circular(AppRadii.full),
          ),
          child: Text(
            count,
            textAlign: TextAlign.center,
            style: AppText.micro.copyWith(
              color: tokens.accentOn,
              fontWeight: AppWeights.semi,
            ),
          ),
        ),
      );
    }
    if (!unread.any) return const SizedBox.shrink();
    return Semantics(
      label: 'Unread messages',
      excludeSemantics: true,
      child: DecoratedBox(
        key: dotKey,
        decoration: BoxDecoration(
          color: tokens.textPrimary,
          borderRadius: BorderRadius.circular(AppRadii.full),
        ),
        child: const SizedBox(width: 8, height: 8),
      ),
    );
  }
}
