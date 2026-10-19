// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a message's context menu holds: the quick reactions, the verbs people
/// use, and a second page for the rare and the destructive-to-someone-else.
///
/// "More" swaps the page in place rather than opening a second surface: a
/// floating submenu under a thumb is what `desktop-vs-mobile.md` forbids, and
/// one swap behaves the same under a pointer, a finger and the keyboard.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/widgets/bot_menu_sections.dart';
import 'message_context_menu.dart';
import '../../emoji/widgets/quick_reactions.dart';

class MessageMenuBody extends StatefulWidget {
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

  @override
  State<MessageMenuBody> createState() => _MessageMenuBodyState();
}

class _MessageMenuBodyState extends State<MessageMenuBody> {
  bool _more = false;

  MessageActions get _a => widget.actions;

  void _run(VoidCallback action) {
    widget.close();
    action();
  }

  void _showMore(bool more) => setState(() => _more = more);

  bool get _hasMore =>
      _a.canReport ||
      _a.canBlockAuthor ||
      (_a.canDelete && _a.onStartSelecting != null);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _more ? _morePage() : _primaryPage(context),
    );
  }

  List<Widget> _primaryPage(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return [
      QuickReactionRow(
        reacted: widget.reacted,
        onPick: widget.onPickReaction,
        onMore: widget.onAddReaction,
        close: widget.close,
      ),
      for (final group in [_replyGroup(tokens), _keepGroup(), _lastGroup()])
        if (group.isNotEmpty) ...[const AppMenuDivider(), ...group],
      ...botMenuItems(_a.botSections, widget.close),
    ];
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
            _run(() => Clipboard.setData(ClipboardData(text: widget.content))),
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
    ];
  }

  List<Widget> _lastGroup() {
    return [
      if (_hasMore)
        AppMenuItem(
          label: 'More',
          leading: AppIcons.moreHorizontal,
          submenu: true,
          onTap: () => _showMore(true),
        ),
      if (_a.canDelete)
        AppMenuItem(
          label: 'Delete',
          leading: AppIcons.delete,
          tone: AppMenuItemTone.danger,
          onTap: () => _run(_a.onDelete),
        ),
    ];
  }

  List<Widget> _morePage() => [
    AppMenuItem(
      label: 'Back',
      leading: AppIcons.back,
      onTap: () => _showMore(false),
    ),
    const AppMenuDivider(),
    if (_a.canDelete)
      if (_a.onStartSelecting case final VoidCallback start)
        AppMenuItem(
          label: 'Select messages',
          leading: AppIcons.check,
          onTap: () => _run(start),
        ),
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
  ];
}

String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;
