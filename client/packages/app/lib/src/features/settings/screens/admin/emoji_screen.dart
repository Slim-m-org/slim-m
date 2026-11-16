// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Custom emoji administration: `GET/POST /emoji` and `DELETE /emoji/{id}`.
/// Requires MANAGE_SERVER, the bit that already means "change what this
/// deployment is".
///
/// Reading the list is open to every member server-side, so the permission
/// this screen is gated on is about the two write actions on it, not about
/// seeing which emoji exist.
library;

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../../widgets/app_drop_zone.dart';
import '../../../../providers/admin_providers.dart';
import '../../providers/display_preferences.dart';
import '../../../../providers/providers.dart';
import '../../../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../emoji/widgets/custom_emoji_image.dart';
import '../../../emoji/widgets/emoji_catalog.dart' show emojiNameMatches;
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_catalog_card.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_section_header.dart';
import 'emoji_create.dart';
import 'emoji_intake.dart';

/// Marks the sizing box around the emoji list, so a test can measure it
/// directly rather than inferring the fix from a screenshot - the same
/// technique `pinnedMessagesBodyBoxKey` uses.
const emojiListBodyBoxKey = Key('emoji_list_body_box');

class EmojiScreen extends StatelessWidget {
  const EmojiScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Emoji',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    actions: [
      EmojiCreateButton(),
      SizedBox(width: AppSpacing.s8),
    ],
    child: EmojiPane(),
  );
}

/// The emoji catalog, embeddable as a Space settings pane as well as routed;
/// its create button sits in the title bar ([EmojiCreateButton]).
///
/// The catalog sits in a [SettingsCatalogCard], whose bounded lazy list only
/// builds the rows on screen: a plain `Column` of every row lagged once a
/// deployment passed a couple hundred emoji.
class EmojiPane extends ConsumerStatefulWidget {
  const EmojiPane({super.key});

  @override
  ConsumerState<EmojiPane> createState() => _EmojiPaneState();
}

class _EmojiPaneState extends ConsumerState<EmojiPane> {
  final _search = TextEditingController();

  Future<void> _dropped(List<DropItem> files) async {
    final picks = await readDroppedEmoji(files);
    if (mounted && picks.isNotEmpty) {
      unawaited(showEmojiAddDialog(context, initial: picks));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final emoji = ref.watch(customEmojiProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return AppDropZone(
      enabled: !ref.watch(emojiAddOpenProvider),
      label: 'Drop to add emoji',
      icon: AppIcons.image,
      onDrop: (files) => unawaited(_dropped(files)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppAsyncView<List<api.CustomEmoji>>(
            value: AppAsyncState(data: emoji.valueOrNull, error: emoji.error),
            center: false,
            errorMessage: 'Could not load emoji.',
            onRetry: () => ref.invalidate(customEmojiProvider),
            data: (context, list) {
              if (list.isEmpty) {
                return SettingsCatalogCard(
                  title: _title,
                  itemCount: 0,
                  itemBuilder: (_, _) => const SizedBox.shrink(),
                  empty: const SettingsEmptyState(
                    icon: AppIcons.smile,
                    title: 'No emoji yet.',
                    detail: 'Create some and members can use them.',
                  ),
                );
              }
              final shown = [
                for (final e in list)
                  if (emojiNameMatches(e.name, _search.text)) e,
              ];
              return SettingsCatalogCard(
                title: _title,
                count: shown.length == list.length
                    ? '${list.length}'
                    : '${shown.length} of ${list.length}',
                above: [
                  SettingsCardBlock(
                    children: [
                      AppInput(
                        controller: _search,
                        placeholder: 'Search emoji',
                        semanticLabel: 'Search emoji',
                        icon: Icon(
                          AppIcons.search,
                          size: AppSizes.icon16,
                          color: tokens.textSecondary,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ],
                  ),
                ],
                listKey: emojiListBodyBoxKey,
                itemCount: shown.length,
                itemBuilder: (context, index) => _EmojiRow(
                  key: ValueKey(shown[index].id),
                  emoji: shown[index],
                ),
                empty: SettingsEmptyState(
                  icon: AppIcons.search,
                  title: 'No emoji match "${_search.text.trim()}".',
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Not the pane's own name, which the title bar above already says.
  static const _title = 'Custom emoji';
}

class _EmojiRow extends ConsumerStatefulWidget {
  const _EmojiRow({super.key, required this.emoji});

  final api.CustomEmoji emoji;

  @override
  ConsumerState<_EmojiRow> createState() => _EmojiRowState();
}

class _EmojiRowState extends ConsumerState<_EmojiRow>
    with GuardedActionState<_EmojiRow> {
  bool _busy = false;

  Future<void> _delete() async {
    final shortcode = widget.emoji.shortcode;
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Remove $shortcode?',
      message:
          'Messages that already use it keep their text, but it stops '
          'rendering as an image. This cannot be undone.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    final ok = await guard(
      // Not "remove $shortcode": a shortcode's own trailing colon collides with the one some failure sentences end in.
      whatFailed: 'remove the $shortcode emoji',
      action: () => ref.read(apiProvider).deleteCustomEmoji(widget.emoji.id),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(customEmojiProvider);
  }

  @override
  Widget build(BuildContext context) {
    final emoji = widget.emoji;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final wide = MediaQuery.sizeOf(context).width >= kCompactWidth;

    return SettingsEntityRow(
      dense: true,
      // The same widget and the same cache a message row draws it through, so this list shows what a member will actually see.
      leading: CustomEmojiImage(emojiId: emoji.id, size: AppSizes.icon24),
      headline: emoji.shortcode,
      headlineStyle: AppText.code,
      badge: wide
          ? Text(
              formatDateTime(
                emoji.createdAt,
                use24Hour: watchUse24Hour(ref, context),
              ),
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            )
          : null,
      actions: [
        AppIconButton(
          icon: AppIcons.delete,
          semanticLabel: 'Remove ${emoji.shortcode}',
          variant: AppIconButtonVariant.danger,
          onPressed: _busy ? null : _delete,
        ),
      ],
      error: actionError,
      onErrorDismiss: clearActionError,
    );
  }
}
