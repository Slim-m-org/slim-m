// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a message's context menu holds: the quick reactions, the verbs people
/// use, and a trailing group for report, block and delete that never moves.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/widgets/bot_menu_sections.dart';
import 'message_context_menu.dart';
import '../../emoji/widgets/quick_reactions.dart';

class MessageMenuBody extends StatelessWidget {
  const MessageMenuBody({
    super.key,
    required this.actions,
    required this.content,
    required this.reacted,
    required this.onAddReaction,
    required this.onPickReaction,
    required this.close,
  });

  final MessageActions actions;
  final String content;
  final Set<String> reacted;
  final VoidCallback onAddReaction;
  final ValueChanged<String> onPickReaction;
  final VoidCallback close;

  MessageActions get _a => actions;

  void _run(VoidCallback action) {
    close();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        QuickReactionRow(
          reacted: reacted,
          onPick: onPickReaction,
          onMore: onAddReaction,
          close: close,
        ),
        for (final group in [_replyGroup(tokens), _keepGroup(), _lastGroup()])
          if (group.isNotEmpty) ...[const AppMenuDivider(), ...group],
        ...botMenuItems(_a.botSections, close),
      ],
    );
  }

  List<Widget> _replyGroup(AppTokens tokens) {
    // See MessageActions.hasExistingThread's own doc comment for why "Reply" stays offered here.
    final showThreadHint = _a.canReply && _a.hasExistingThread;
    return [
      if (_a.canReply)
        AppMenuItem(
          label: 'Reply',
          leading: AppIcons.reply,
          // A glyph, not text: this row is only 200px wide, with no room for a second string.
          trailing: showThreadHint
              ? Icon(
                  AppIcons.thread,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                )
              : null,
          semanticLabel: showThreadHint
              ? 'Reply. A thread already exists on this message.'
              : null,
          onTap: () => _run(_a.onReply),
        ),
      if (_a.canOpenThread)
        AppMenuItem(
          label: 'Reply in thread',
          leading: AppIcons.thread,
          onTap: () => _run(_a.onOpenThread),
        ),
      if (_a.canEdit)
        AppMenuItem(
          label: 'Edit',
          leading: AppIcons.edit,
          onTap: () => _run(_a.onEdit),
        ),
    ];
  }

  List<Widget> _keepGroup() {
    return [
      AppMenuItem(
        label: 'Copy text',
        leading: AppIcons.copy,
        onTap: () =>
            _run(() => Clipboard.setData(ClipboardData(text: content))),
      ),
      if (_a.canCopyLink)
        AppMenuItem(
          label: 'Copy message link',
          leading: AppIcons.link,
          onTap: () => _run(_a.onCopyLink),
        ),
      for (final url in _a.linkUrls)
        if (_a.onCopyLinkAddress case final copy?)
          AppMenuItem(
            label: _a.linkUrls.length == 1
                ? 'Copy link address'
                : 'Copy link address (${_hostOf(url)})',
            leading: AppIcons.link,
            onTap: () => _run(() => copy(url)),
          ),
      if (_a.canForward)
        AppMenuItem(
          label: 'Forward message',
          leading: AppIcons.forward,
          onTap: () => _run(_a.onForward),
        ),
      if (_a.canSave)
        AppMenuItem(
          label: 'Save message',
          leading: AppIcons.bookmark,
          onTap: () => _run(_a.onSave),
        ),
      if (_a.canManagePins)
        AppMenuItem(
          label: _a.pinned ? 'Unpin' : 'Pin',
          leading: AppIcons.pin,
          onTap: () => _run(_a.onTogglePin),
        ),
      if (_a.canDelete)
        if (_a.onStartSelecting case final VoidCallback start)
          AppMenuItem(
            label: 'Select messages',
            leading: AppIcons.check,
            onTap: () => _run(start),
          ),
    ];
  }

  List<Widget> _lastGroup() {
    return [
      if (_a.canReport)
        AppMenuItem(
          label: 'Report message',
          leading: AppIcons.report,
          onTap: () => _run(_a.onReport),
        ),
      if (_a.canBlockAuthor)
        AppMenuItem(
          label: 'Block user',
          leading: AppIcons.revoke,
          tone: AppMenuItemTone.danger,
          onTap: () => _run(_a.onBlockAuthor),
        ),
      if (_a.canDelete) ...[
        if (_a.canReport || _a.canBlockAuthor) const AppMenuDivider(),
        AppMenuItem(
          label: 'Delete',
          leading: AppIcons.delete,
          tone: AppMenuItemTone.danger,
          onTap: () => _run(_a.onDelete),
        ),
      ],
    ];
  }
}

String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;
