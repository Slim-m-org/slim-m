// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One bot in the Bots pane: a single line, with every action in one menu.
///
/// The kebab, a right-click and a long-press all open the same menu
/// (`docs/design/desktop-vs-mobile.md`, rule 1).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/context_menu_region.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import 'bot_permissions_sheet.dart';
import 'bot_prefix_sheet.dart';
import 'bot_row_line.dart';

class BotRow extends ConsumerStatefulWidget {
  const BotRow({
    super.key,
    required this.bot,
    required this.onReissued,
    required this.canReissue,
  });

  final api.Bot bot;
  final bool canReissue;

  /// Hands the new token up to the pane, which shows it once.
  final ValueChanged<api.NewBot> onReissued;

  @override
  ConsumerState<BotRow> createState() => _BotRowState();
}

class _BotRowState extends ConsumerState<BotRow>
    with GuardedActionState<BotRow> {
  bool _busy = false;
  final _menu = GlobalKey<ContextMenuRegionState>();
  final _kebab = GlobalKey();

  /// Lets a second press on the kebab count as inside the open menu, so it closes it.
  final _menuGroup = Object();

  Future<void> _revoke() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Revoke ${widget.bot.displayName}?',
      message:
          'Its token and every session it holds stop working now. '
          'You can issue it a new token afterwards.',
      confirmLabel: 'Revoke',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'revoke ${widget.bot.username}',
      action: () => ref.read(apiProvider).revokeBot(widget.bot.userId),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(botsProvider);
  }

  Future<void> _reissue() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Re-issue ${widget.bot.displayName}\'s token?',
      message:
          'The old token stops working now. The bot needs the new one to '
          'reconnect.',
      confirmLabel: 'Re-issue',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    api.NewBot? issued;
    final ok = await guard(
      whatFailed: 'issue ${widget.bot.username} a new token',
      action: () async {
        issued = await ref.read(apiProvider).reissueBotToken(widget.bot.userId);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    ref.invalidate(botsProvider);
    widget.onReissued(issued!);
  }

  /// Built with the row's own context: the sheets and dialogs these open must outlive the menu that opened them.
  List<Widget> _menuItems(BuildContext _, VoidCallback close) {
    final bot = widget.bot;
    final canAct = !_busy;
    return [
      if (!bot.isRevoked)
        AppMenuItem(
          label: 'Permissions',
          leading: AppIcons.permissions,
          trailing: _hint(_permissionCount(bot)),
          onTap: () {
            close();
            unawaited(showBotPermissionsSheet(context, bot));
          },
        ),
      if (!bot.isRevoked)
        AppMenuItem(
          label: 'Prefix',
          leading: AppIcons.edit,
          trailing: _hint(bot.prefix, mono: true),
          onTap: () {
            close();
            unawaited(showBotPrefixSheet(context, bot));
          },
        ),
      AppMenuItem(
        label: 'Re-issue token',
        leading: AppIcons.resetCode,
        onTap: canAct && widget.canReissue
            ? () {
                close();
                unawaited(_reissue());
              }
            : null,
      ),
      if (!bot.isRevoked) ...[
        const AppMenuDivider(),
        AppMenuItem(
          label: 'Revoke',
          leading: AppIcons.revoke,
          tone: AppMenuItemTone.danger,
          onTap: canAct
              ? () {
                  close();
                  unawaited(_revoke());
                }
              : null,
        ),
      ],
    ];
  }

  Widget? _hint(String? text, {bool mono = false}) {
    if (text == null) return null;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 96),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.caption.copyWith(
          color: tokens.textSecondary,
          fontFamily: mono ? AppFonts.mono : null,
        ),
      ),
    );
  }

  Widget _kebabButton() {
    // Anchored under the button: the region's own default would land at the row's left edge, a screen away from it.
    Offset? below() {
      final box = _kebab.currentContext?.findRenderObject() as RenderBox?;
      return box?.localToGlobal(Offset(0, box.size.height));
    }

    return TapRegion(
      groupId: _menuGroup,
      child: AppIconButton(
        key: _kebab,
        icon: AppIcons.moreVertical,
        semanticLabel: 'Manage ${widget.bot.displayName}',
        size: AppIconButtonSize.sm,
        onPressed: () => _menu.currentState?.toggle(at: below()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final line = ContextMenuRegion(
      key: _menu,
      itemsBuilder: _menuItems,
      // The kebab is already this row's tab stop.
      ownsFocusNode: false,
      menuWidth: 240,
      tapRegionGroupId: _menuGroup,
      child: BotRowLine(bot: widget.bot, kebab: _kebabButton()),
    );
    final error = actionError;
    if (error == null) return line;
    final inset = SettingsRowMetrics.of(context).inset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        line,
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, AppSpacing.s12),
          child: AppErrorState(message: error, onDismiss: clearActionError),
        ),
      ],
    );
  }
}

String _permissionCount(api.Bot bot) {
  final count = Perm.editable
      .where((e) => bot.permissions.hasPermission(e.$1))
      .length;
  return count == 0 ? 'None' : '$count';
}
