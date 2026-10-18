// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Provisioning bots and their permission grant. See
/// `docs/decisions/0028-bot-accounts.md`.
///
/// The token is shown once, here, and unrecoverable afterwards.
library;

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
import '../../widgets/settings_disclosure.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_secret_reveal.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import '../../../../action_labels.dart';

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
        'dispose failed, ignored',
        error,
        stack,
      );
      return;
    }
  }

  Future<void> _create() async {
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
            warning:
                'This is the only time ${created.bot.username}\'s token is '
                'shown. Copy it now - the server keeps only a hash, so it '
                'cannot be shown again. Revoke the bot and make another if '
                'you lose it.',
            value: created.token,
            valueSemanticsLabel: 'Bot token for ${created.bot.username}',
            copyLabel: 'Copy token',
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
                    onPressed: _busy ? null : _create,
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
                for (final bot in list) _BotRow(bot: bot),
            ],
          ),
        ),
      ],
    );
  }
}

class _BotRow extends ConsumerStatefulWidget {
  const _BotRow({required this.bot});

  final api.Bot bot;

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
          'This cannot be undone; make a new bot to replace it.',
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
      detail: bot.isRevoked
          ? 'Revoked. Kept for what it wrote.'
          : [
              if (bot.prefix case final prefix?) 'Prefix $prefix.',
              bot.tokenLastUsedAt == null ? 'Never used yet.' : 'Token active.',
              count == 0
                  ? 'No permissions granted yet'
                  : count == 1
                  ? '1 permission granted'
                  : '$count permissions granted',
            ].join(' '),
      dimmed: bot.isRevoked,
      stackTrailingWhenNarrow: true,
      trailing: bot.isRevoked
          ? null
          : Wrap(
              spacing: AppSpacing.s8,
              runSpacing: AppSpacing.s8,
              children: [
                AppButton(
                  label: 'Permissions',
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  onPressed: () => showBotPermissionsSheet(context, bot),
                ),
                AppButton(
                  label: 'Revoke',
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.sm,
                  onPressed: _busy ? null : _revoke,
                ),
              ],
            ),
      error: actionError,
      onErrorDismiss: clearActionError,
    );
  }
}

/// Opens the permission editor for one bot's managed role.
Future<void> showBotPermissionsSheet(BuildContext context, api.Bot bot) {
  return showAppSheet<void>(
    context,
    scrolls: true,
    builder: (context) => _BotPermissionsSheet(bot: bot),
  );
}

class _BotPermissionsSheet extends ConsumerStatefulWidget {
  const _BotPermissionsSheet({required this.bot});

  final api.Bot bot;

  @override
  ConsumerState<_BotPermissionsSheet> createState() =>
      _BotPermissionsSheetState();
}

class _BotPermissionsSheetState extends ConsumerState<_BotPermissionsSheet>
    with GuardedActionState<_BotPermissionsSheet> {
  late int _permissions = widget.bot.permissions;
  bool _submitting = false;

  Future<void> _submit() async {
    clearActionError();
    setState(() => _submitting = true);
    final ok = await guard(
      whatFailed: "save ${widget.bot.displayName}'s permissions",
      action: () => ref
          .read(apiProvider)
          .setBotPermissions(widget.bot.userId, _permissions),
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _submitting = false);
      return;
    }
    ref.invalidate(botsProvider);
    Navigator.of(context).pop();
  }

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "${widget.bot.displayName}'s permissions",
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Close',
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: AppSpacing.s4),
                  Text(
                    'You can never grant more than you hold yourself.',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  BotPermissionToggles(
                    value: _permissions,
                    onChanged: (v) => setState(() => _permissions = v),
                  ),
                ],
              ),
            ),
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: actionError!),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: _submitting ? 'Saving...' : 'Save changes',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: _submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
