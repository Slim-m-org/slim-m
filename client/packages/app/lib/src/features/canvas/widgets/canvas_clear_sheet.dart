// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet behind "Clear part of the canvas": one danger row per kind of
/// content or person, each clearing on tap.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';
import 'canvas_clear_scope.dart';

/// Offers the scopes and clears the one tapped; the sheet is the confirmation.
Future<void> requestScopedCanvasClear(
  BuildContext context,
  CanvasScopedClear control,
) async {
  final choice = await showAppSheet<CanvasClearChoice>(
    context,
    scrolls: true,
    semanticLabel: 'Clear part of the canvas',
    builder: (_) => _CanvasClearSheet(authorIds: control.authorIds().toList()),
  );
  if (choice == null || !context.mounted) return;
  await control.clear(choice.scope);
}

class _CanvasClearSheet extends ConsumerWidget {
  const _CanvasClearSheet({required this.authorIds});

  final List<String> authorIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final profiles = ref.watch(batchProfilesControllerProvider);

    final uncached = authorIds.where((id) => !profiles.containsKey(id)).toSet();
    if (uncached.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ref.read(batchProfilesControllerProvider.notifier).resolve(uncached);
        }
      });
    }

    final sortedAuthorIds = authorIds.toList()
      ..sort((a, b) {
        final nameA = profiles[a]?.displayName ?? profiles[a]?.username ?? a;
        final nameB = profiles[b]?.displayName ?? profiles[b]?.username ?? b;
        return nameA.toLowerCase().compareTo(nameB.toLowerCase());
      });

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
          const AppSheetHeader(
            'Clear part of the canvas',
            caption:
                'Removes it for everyone in this channel. Undo works until you close the canvas.',
            padding: EdgeInsets.only(bottom: AppSpacing.s8),
          ),
          // The sheet is bounded (scrolls: true), so the choices scroll under the pinned heading.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final target in CanvasClearTarget.values)
                    AppMenuItem(
                      label: 'Clear all ${target.label.toLowerCase()}',
                      leading: AppIcons.eraser,
                      tone: AppMenuItemTone.danger,
                      onTap: () => Navigator.of(
                        context,
                      ).pop(CanvasClearChoice(target.scope)),
                    ),
                  if (sortedAuthorIds.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s12),
                    Text(
                      'One person\'s content (people in view)',
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    for (final id in sortedAuthorIds) _AuthorRow(authorId: id),
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

class _AuthorRow extends ConsumerWidget {
  const _AuthorRow({required this.authorId});

  final String authorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider(authorId)).valueOrNull;
    final name = profile?.displayName ?? profile?.username ?? 'Unknown member';
    return AppMenuItem(
      label: '$name\'s content',
      tone: AppMenuItemTone.danger,
      leadingWidget: UserAvatar(
        name: name,
        userId: authorId,
        size: AppAvatarSize.s24,
      ),
      onTap: () => Navigator.of(
        context,
      ).pop(CanvasClearChoice(api.CanvasClearScope(authorId: authorId))),
    );
  }
}
