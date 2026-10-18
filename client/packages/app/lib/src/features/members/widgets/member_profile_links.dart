// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile card's row for a linked Discord account, absent without one.
/// Tapping copies the username.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/toasts.dart';
import '../../settings/widgets/connections_section.dart' show discordLabel;
import '../providers/user_linked_accounts.dart';
import 'linked_account_picture.dart';

class MemberProfileLinks extends ConsumerWidget {
  const MemberProfileLinks({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(userLinkedAccountsProvider(userId)).valueOrNull;
    final discord = links?.where((link) => link.isDiscord).firstOrNull;
    if (discord == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Semantics(
        button: true,
        label: 'Copy Discord username ${discord.username}',
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.control),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: discord.username));
            ref
                .read(toastsProvider.notifier)
                .show('Username copied.', severity: AppToastSeverity.success);
          },
          child: ExcludeSemantics(
            child: Row(
              spacing: AppSpacing.s8,
              children: [
                LinkedAccountPicture(
                  userId: userId,
                  account: discord,
                  size: AppAvatarSize.s20,
                  fallback: Icon(
                    AppIcons.link,
                    size: 14,
                    color: tokens.textSecondary,
                  ),
                ),
                Flexible(
                  child: Text(
                    'Discord · ${discordLabel(discord)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
