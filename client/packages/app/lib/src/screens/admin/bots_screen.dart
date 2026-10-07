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

import '../../permissions.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../routing/routes.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/labeled_field.dart';
import '../../widgets/permission_row.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_notice.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import '../../action_labels.dart';

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
  bool _busy = false;

  /// The bot's managed-role grant. Defaults to none.
  int _permissions = 0;

  /// The one and only time this token is legible. Held in state rather than
  /// pushed into a toast, so it stays on screen until it is dismissed.
  api.NewBot? _justCreated;

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final username = _username.text.trim();
    if (username.isEmpty) return;
    setState(() => _busy = true);
    api.NewBot? created;
    final ok = await guard(
      whatFailed: 'create the bot',
      action: () async {
        created = await ref
            .read(apiProvider)
            .createBot(username, permissions: _permissions);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _justCreated = created;
        _username.clear();
        _permissions = 0;
      }
    });
    if (ok) ref.invalidate(botsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final bots = ref.watch(botsProvider);
    final myPermissions = ref.watch(myPermissionsProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_justCreated case final created?) ...[
          _TokenReveal(
            created: created,
            onDismiss: () => setState(() => _justCreated = null),
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        const SettingsSectionHeader(ActionLabels.createBot),
        SettingsSectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: 'Username',
              helper: 'Letters, digits, _ . and - only, up to 32 characters.',
              child: AppInput(
                controller: _username,
                autocorrect: false,
                semanticLabel: 'Bot username',
                onSubmitted: (_) => _busy ? null : _create(),
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            Text(
              'Permissions',
              style: AppText.label.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Grant only what the bot needs.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            for (final (bit, label) in Perm.editable)
              PermissionRow(
                label: label,
                dimmed: !myPermissions.hasPermission(bit),
                control: AppToggle(
                  value: _permissions.hasPermission(bit),
                  semanticLabel: label,
                  onChanged: myPermissions.hasPermission(bit)
                      ? (v) => setState(() {
                          _permissions = v
                              ? (_permissions | bit)
                              : (_permissions & ~bit);
                        })
                      : null,
                ),
              ),
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: ActionLabels.createBot,
              variant: AppButtonVariant.primary,
              onPressed: _busy ? null : _create,
            ),
            if (actionError case final error?) ...[
              const SizedBox(height: AppSpacing.s12),
              SettingsNotice(icon: AppIcons.warning, message: error),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.s24),
        const SettingsSectionHeader('Bots in this Space'),
        AppAsyncView<List<api.Bot>>(
          value: AppAsyncState(data: bots.valueOrNull, error: bots.error),
          center: false,
          errorMessage: 'Could not load the bots.',
          onRetry: () => ref.invalidate(botsProvider),
          isEmpty: (list) => list.isEmpty,
          emptyMessage: 'No bots yet.',
          data: (context, list) => SettingsSectionCard(
            children: [for (final bot in list) _BotRow(bot: bot)],
          ),
        ),
      ],
    );
  }
}

/// The created bot's token, shown once.
class _TokenReveal extends StatelessWidget {
  const _TokenReveal({required this.created, required this.onDismiss});

  final api.NewBot created;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsNotice(
          icon: AppIcons.warning,
          message:
              'This is the only time ${created.bot.username}\'s token is '
              'shown. Copy it now - the server keeps only a hash, so it '
              'cannot be shown again. Revoke the bot and make another if you '
              'lose it.',
        ),
        const SizedBox(height: AppSpacing.s12),
        SelectableText(
          created.token,
          style: AppText.code,
          semanticsLabel: 'Bot token for ${created.bot.username}',
        ),
        const SizedBox(height: AppSpacing.s12),
        Row(
          children: [
            AppButton(
              label: 'Copy token',
              variant: AppButtonVariant.primary,
              size: AppButtonSize.sm,
              icon: AppIcons.copy,
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: created.token)),
            ),
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              label: 'Done',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              onPressed: onDismiss,
            ),
          ],
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

    return SettingsEntityRow(
      headline: bot.displayName,
      details: [
        SettingsEntityDetail('@${bot.username}'),
        if (bot.isRevoked)
          const SettingsAbsentValue('Revoked. Kept for what it wrote.')
        else if (bot.tokenLastUsedAt == null)
          const SettingsAbsentValue('Never used yet.')
        else
          const SettingsEntityDetail('Token active.'),
        if (!bot.isRevoked)
          SettingsEntityDetail(
            count == 0
                ? 'No permissions granted yet'
                : count == 1
                ? '1 permission granted'
                : '$count permissions granted',
          ),
      ],
      actions: [
        if (!bot.isRevoked)
          AppButton(
            label: 'Permissions',
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: () => showBotPermissionsSheet(context, bot),
          ),
        if (!bot.isRevoked)
          AppButton(
            label: 'Revoke',
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: _busy ? null : _revoke,
          ),
      ],
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
    final myPermissions = ref.watch(myPermissionsProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
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
                  for (final (bit, label) in Perm.editable)
                    PermissionRow(
                      label: label,
                      dimmed: !myPermissions.hasPermission(bit),
                      control: AppToggle(
                        value: _permissions.hasPermission(bit),
                        semanticLabel: label,
                        onChanged: myPermissions.hasPermission(bit)
                            ? (v) => setState(() {
                                _permissions = v
                                    ? (_permissions | bit)
                                    : (_permissions & ~bit);
                              })
                            : null,
                      ),
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
