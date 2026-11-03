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
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_section_header.dart';
import '../../../../widgets/sheet_item_list.dart';
import 'emoji_add_dialog.dart';
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
    child: EmojiPane(),
  );
}

/// The emoji catalog with an Add button that opens the staging dialog, embeddable as a Space settings pane as
/// well as routed.
///
/// The catalog itself sits in a bounded box handed to [SheetItemList]: a
/// plain `Column` of every row used to lag once a deployment passed a
/// couple hundred emoji, because it built, laid out and fetched the image
/// for every row regardless of what was actually on screen. Bounding the
/// box and reusing the same lazy list the pin/thread sheets already use
/// means a large catalog only ever realizes the rows actually visible.
class EmojiPane extends ConsumerStatefulWidget {
  const EmojiPane({super.key});

  @override
  ConsumerState<EmojiPane> createState() => _EmojiPaneState();
}

class _EmojiPaneState extends ConsumerState<EmojiPane> {
  final _search = TextEditingController();
  bool _dialogOpen = false;

  Future<void> _openAdd([List<EmojiPick> initial = const []]) async {
    setState(() => _dialogOpen = true);
    await showEmojiAddDialog(context, initial: initial);
    if (mounted) setState(() => _dialogOpen = false);
  }

  Future<void> _dropped(List<DropItem> files) async {
    final picks = await readDroppedEmoji(files);
    if (mounted && picks.isNotEmpty) unawaited(_openAdd(picks));
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
      enabled: !_dialogOpen,
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
                return SettingsSectionCard(
                  title: 'Emoji (0)',
                  children: [
                    const SettingsEmptyState(
                      icon: AppIcons.smile,
                      title: 'No emoji yet.',
                      detail: 'Add some and members can use them.',
                    ),
                    SettingsCardBlock(children: [_addButton()]),
                  ],
                );
              }
              final shown = [
                for (final e in list)
                  if (emojiNameMatches(e.name, _search.text)) e,
              ];
              return SettingsSectionCard(
                title: shown.length == list.length
                    ? 'Emoji (${list.length})'
                    : 'Emoji (${shown.length} of ${list.length})',
                children: [
                  SettingsCardBlock(
                    children: [
                      Row(
                        spacing: AppSpacing.s8,
                        children: [
                          Expanded(
                            child: AppInput(
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
                          ),
                          _addButton(),
                        ],
                      ),
                    ],
                  ),
                  if (shown.isEmpty)
                    SettingsEmptyState(
                      icon: AppIcons.search,
                      title: 'No emoji match "${_search.text.trim()}".',
                    )
                  else
                    ConstrainedBox(
                      key: emojiListBodyBoxKey,
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
                      ),
                      child: SheetItemList(
                        padding: EdgeInsets.zero,
                        itemCount: shown.length,
                        itemBuilder: (context, index) => _EmojiRow(
                          key: ValueKey(shown[index].id),
                          emoji: shown[index],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _addButton() =>
      AppButton(label: 'Add', icon: AppIcons.add, onPressed: _openAdd);
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
