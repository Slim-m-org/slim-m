// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet behind "Clear part of the canvas": pick a kind of content or one
/// person's, then confirm.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/confirm_dialog.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';
import 'canvas_clear_scope.dart';

/// Offers the scopes, confirms, and answers whether the clear ran.
Future<void> requestScopedCanvasClear(
  BuildContext context,
  CanvasScopedClear control,
) async {
  final choice = await showAppSheet<CanvasClearChoice>(
    context,
    scrolls: true,
    builder: (_) => _CanvasClearSheet(authorIds: control.authorIds().toList()),
  );
  if (choice == null || !context.mounted) return;
  final confirmed = await confirmDangerousAction(
    context,
    title: 'Clear ${choice.subject}?',
    message:
        'This removes ${choice.subject} for everyone in this channel, '
        'including anything outside your current view. You can undo this '
        'with Undo until you close the canvas or take many more actions.',
    confirmLabel: 'Clear',
    cancelLabel: 'Keep it',
  );
  if (confirmed) await control.clear(choice.scope);
}

class _CanvasClearSheet extends StatelessWidget {
  const _CanvasClearSheet({required this.authorIds});

  final List<String> authorIds;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Clear part of the canvas',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          for (final target in CanvasClearTarget.values)
            AppListRow(
              label: 'All ${target.label.toLowerCase()}',
              leading: Icon(
                AppIcons.delete,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              onTap: () => Navigator.of(context).pop(
                CanvasClearChoice(
                  target.scope,
                  'all ${target.label.toLowerCase()}',
                ),
              ),
            ),
          if (authorIds.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s12),
            Text(
              'One person\'s content (people in view)',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            for (final id in authorIds) _AuthorRow(authorId: id),
          ],
        ],
      ),
    );
  }
}

class _AuthorRow extends ConsumerWidget {
  const _AuthorRow({required this.authorId});

  final String authorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name =
        ref.watch(userProfileProvider(authorId)).valueOrNull?.displayName ??
        'Unknown member';
    return AppListRow(
      label: name,
      leading: UserAvatar(
        name: name,
        userId: authorId,
        size: AppAvatarSize.s24,
      ),
      onTap: () => Navigator.of(context).pop(
        CanvasClearChoice(
          api.CanvasClearScope(authorId: authorId),
          '$name\'s content',
        ),
      ),
    );
  }
}
