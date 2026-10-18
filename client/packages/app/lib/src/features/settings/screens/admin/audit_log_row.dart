// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One audit-log row: who, what they changed, and when.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../members/providers/user_profiles.dart';
import '../../../members/widgets/user_avatar.dart';
import '../../providers/admin_audit_names.dart';
import '../../providers/admin_audit_wording.dart';
import '../../providers/display_preferences.dart';

class AuditLogRow extends ConsumerWidget {
  const AuditLogRow({super.key, required this.change});

  final api.AdminChange change;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final profiles = ref.watch(batchProfilesControllerProvider);
    final actorId = change.actorId;
    final actor = actorId == null
        ? 'Deleted account'
        : profiles.containsKey(actorId)
        ? profiles[actorId]?.displayName ?? 'Deleted account'
        : 'Loading...';
    final sentence = describeAdminChange(
      change,
      ref.watch(adminAuditNamesProvider),
    );
    final use24Hour = watchUse24Hour(ref, context);
    final exact = formatDateTime(change.createdAt, use24Hour: use24Hour);
    return Tooltip(
      message: exact,
      triggerMode: TooltipTriggerMode.longPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatar(name: actor, userId: actorId, size: AppAvatarSize.s36),
            const SizedBox(width: AppSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: actor,
                          style: const TextStyle(fontWeight: AppWeights.semi),
                        ),
                        TextSpan(text: ' $sentence'),
                      ],
                    ),
                    style: AppText.body.copyWith(color: tokens.textPrimary),
                  ),
                  Text(
                    formatRelativeAgeMs(change.createdAt, weeks: true),
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
