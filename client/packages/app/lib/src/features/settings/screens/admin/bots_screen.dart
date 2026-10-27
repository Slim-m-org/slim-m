// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Provisioning bots and their permission grant. See
/// `docs/decisions/0028-bot-accounts.md`.
///
/// The token is shown once, here, and unrecoverable afterwards.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../routing/routes.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/labeled_field.dart';
import '../../../members/widgets/bot_permission_toggles.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/bot_env_block.dart';
import '../../widgets/bot_status_badge.dart';
import '../../widgets/settings_disclosure.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_secret_reveal.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'bot_permissions_sheet.dart';
export 'bot_permissions_sheet.dart' show showBotPermissionsSheet;
import '../../../../action_labels.dart';
import '../../../../format.dart';

class BotsScreen extends StatelessWidget {
  const BotsScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Bots',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: BotsPane(),
  );
}

class BotsPane extends ConsumerStatefulWidget {
  const BotsPane({super.key});

  @override
  ConsumerState<BotsPane> createState() => _BotsPaneState();
}

class _BotsPaneState extends ConsumerState<BotsPane>
    with GuardedActionState<BotsPane> {
  final _username = TextEditingController();
  final _prefix = TextEditingController();
  bool _busy = false;

  /// The bot's managed-role grant. Defaults to none.
  int _permissions = 0;

  /// The one and only time this token is legible. Held in state rather than
  /// pushed into a toast, so it stays on screen until it is dismissed.
  api.NewBot? _justCreated;
  final _revealKey = GlobalKey();

  void _showReveal(api.NewBot issued) {
    setState(() => _justCreated = issued);
    // The reveal sits above the list, so a re-issue from a low row must scroll to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final revealed = _revealKey.currentContext;
      if (revealed == null || !revealed.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          revealed,
          duration: const Duration(milliseconds: 200),
        ),
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _suggestPrefix();
  }

  @override
  void dispose() {
    _username.dispose();
    _prefix.dispose();
    super.dispose();
  }

  /// Fills the field with a free prefix the admin can accept or overtype.
  /// Left empty when the suggestion fails: the server picks one on create.
  Future<void> _suggestPrefix({bool refresh = false}) async {
    if (refresh) ref.invalidate(suggestedBotPrefixProvider);
    try {
      final suggestion = await ref.read(suggestedBotPrefixProvider.future);
      if (mounted && _prefix.text.isEmpty) _prefix.text = suggestion;
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'Could not suggest a bot prefix; leaving it empty',
        error,
        stack,
      );
      return;
    }
  }

  Future<void> _create() async {
    // A pending reveal is the only copy of the last bot's token, so a second create waits for it.
    if (_justCreated != null) return;
    final username = _username.text.trim();
    if (username.isEmpty) return;
    final prefix = _prefix.text.trim();
    setState(() => _busy = true);
    api.NewBot? created;
    final ok = await guard(
      whatFailed: 'create the bot',
      action: () async {
        created = await ref
            .read(apiProvider)
            .createBot(
              username,
              permissions: _permissions,
              prefix: prefix.isEmpty ? null : prefix,
            );
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _justCreated = created;
        _username.clear();
        _prefix.clear();
        _permissions = 0;
      }
    });
    if (ok) {
      ref.invalidate(botsProvider);
      await _suggestPrefix(refresh: true);
    }
  }

  String _permissionsSummary() {
    final count = Perm.editable
        .where((e) => _permissions.hasPermission(e.$1))
        .length;
    return count == 0 ? 'None granted' : '$count granted';
  }

  @override
  Widget build(BuildContext context) {
    final bots = ref.watch(botsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_justCreated case final created?)
          SettingsSecretReveal(
            key: _revealKey,
            warning:
                'This is the only time ${created.bot.username}\'s token is '
                'shown. Copy it now - the server keeps only a hash, so it '
                'cannot be shown again. Re-issue it from the bot\'s row if '
                'you lose it.',
            value: created.token,
            valueSemanticsLabel: 'Bot token for ${created.bot.username}',
            copyLabel: 'Copy token',
            extraCopyLabel: 'Copy env block',
            extraCopyValue: botEnvBlock(
              url: ref.read(serverUrlProvider),
              token: created.token,
            ),
            onDismiss: () => setState(() => _justCreated = null),
          ),
        SettingsSectionCard(
          title: ActionLabels.createBot,
          children: [
            SettingsCardBlock(
              gap: AppSpacing.s12,
              children: [
                LabeledField(
                  label: 'Username',
                  helper:
                      'Letters, digits, _ . and - only, up to 32 characters.',
                  child: AppInput(
                    maxLength: api.InputLimits.username,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(api.usernameCharacters),
                    ],
                    controller: _username,
                    autocorrect: false,
                    semanticLabel: 'Bot username',
                    onSubmitted: (_) => _busy ? null : _create(),
                  ),
                ),
                LabeledField(
                  label: 'Command prefix',
                  helper:
                      'Typed before a command. Bots can share one while '
                      'their commands differ.',
                  child: AppInput(
                    maxLength: api.InputLimits.botPrefix,
                    inputFormatters: [
                      FilteringTextInputFormatter.deny(RegExp(r'\s')),
                    ],
                    controller: _prefix,
                    autocorrect: false,
                    mono: true,
                    semanticLabel: 'Bot command prefix',
                    onSubmitted: (_) => _busy ? null : _create(),
                  ),
                ),
                SettingsDisclosure(
                  title: 'Permissions',
                  summary: _permissionsSummary(),
                  children: [
                    BotPermissionToggles(
                      value: _permissions,
                      onChanged: (v) => setState(() => _permissions = v),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppButton(
                    label: ActionLabels.createBot,
                    variant: AppButtonVariant.primary,
                    onPressed: _busy || _justCreated != null ? null : _create,
                  ),
                ),
                if (_justCreated != null)
                  Text(
                    'Copy or dismiss the token above first.',
                    style: AppText.caption.copyWith(
                      color: Theme.of(
                        context,
                      ).extension<AppTokens>()!.textSecondary,
                    ),
                  ),
                if (actionError case final error?)
                  AppErrorState(message: error, onDismiss: clearActionError),
              ],
            ),
          ],
        ),
        AppAsyncView<List<api.Bot>>(
          value: AppAsyncState(data: bots.valueOrNull, error: bots.error),
          center: false,
          errorMessage: 'Could not load the bots.',
          onRetry: () => ref.invalidate(botsProvider),
          data: (context, list) => SettingsSectionCard(
            title: 'Bots in this Space',
            children: [
              if (list.isEmpty)
                const SettingsEmptyState(
                  icon: AppIcons.botAction,
                  title: 'No bots yet.',
                  detail: 'Create one above to give an integration an account.',
                )
              else
                for (final bot in list)
                  _BotRow(
                    bot: bot,
                    // A pending reveal is the only copy of that token.
                    canReissue: _justCreated == null,
                    onReissued: _showReveal,
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BotRow extends ConsumerStatefulWidget {
  const _BotRow({
    required this.bot,
    required this.onReissued,
    required this.canReissue,
  });

  final api.Bot bot;
  final bool canReissue;

  /// Hands the new token up to the pane, which shows it once.
  final ValueChanged<api.NewBot> onReissued;

  @override
  ConsumerState<_BotRow> createState() => _BotRowState();
}

class _BotRowState extends ConsumerState<_BotRow>
    with GuardedActionState<_BotRow> {
  bool _busy = false;

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

  Widget _actions(BuildContext context, api.Bot bot) {
    return Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: [
        if (!bot.isRevoked)
          AppButton(
            label: 'Permissions',
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: () => showBotPermissionsSheet(context, bot),
          ),
        AppButton(
          label: 'Re-issue token',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: _busy || !widget.canReissue ? null : _reissue,
        ),
        if (!bot.isRevoked)
          AppButton(
            label: 'Revoke',
            variant: AppButtonVariant.danger,
            size: AppButtonSize.sm,
            onPressed: _busy ? null : _revoke,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bot = widget.bot;
    final count = Perm.editable
        .where((e) => bot.permissions.hasPermission(e.$1))
        .length;

    return SettingsDetailRow(
      icon: AppIcons.botAction,
      title: bot.displayName,
      meta: '@${bot.username}',
      badge: bot.isRevoked ? null : BotStatusBadge(online: bot.online),
      detail: _detail(bot, count),
      dimmed: bot.isRevoked,
      stackTrailingWhenNarrow: true,
      trailing: _actions(context, bot),
      error: actionError,
      onErrorDismiss: clearActionError,
    );
  }
}

String _detail(api.Bot bot, int count) {
  if (bot.isRevoked) return 'Revoked. Re-issue a token to bring it back.';
  return [
    if (bot.prefix case final prefix?) 'Prefix $prefix.',
    if (!bot.online) _lastSeen(bot.tokenLastUsedAt),
    _permissionsGranted(count),
  ].join(' ');
}

String _permissionsGranted(int count) => switch (count) {
  0 => 'No permissions granted yet',
  1 => '1 permission granted',
  _ => '$count permissions granted',
};

String _lastSeen(int? lastUsedMs) => lastUsedMs == null
    ? 'Never connected.'
    : 'Last seen ${formatRelativeAgeMs(lastUsedMs)}.';
