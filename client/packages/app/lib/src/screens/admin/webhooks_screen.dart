// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Minting, listing, renaming, rotating and revoking webhooks. See
/// `docs/decisions/0030-incoming-webhooks.md`.
///
/// The delivery URL is shown once, here, and unrecoverable afterwards -
/// mirroring `bots_screen.dart`'s token reveal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import '../../api_failure.dart';
import '../../format.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../routing/routes.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/labeled_field.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_entity_row.dart';
import '../../widgets/settings_notice.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'overwrite_target_picker_sheets.dart';
import '../../action_labels.dart';

class WebhooksScreen extends StatelessWidget {
  const WebhooksScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Webhooks',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: WebhooksPane(),
  );
}

class WebhooksPane extends ConsumerStatefulWidget {
  const WebhooksPane({super.key});

  @override
  ConsumerState<WebhooksPane> createState() => _WebhooksPaneState();
}

class _WebhooksPaneState extends ConsumerState<WebhooksPane>
    with GuardedActionState<WebhooksPane> {
  final _label = TextEditingController();
  Channel? _channel;
  bool _busy = false;

  /// The one and only time this delivery URL is legible.
  ({api.NewWebhook created, Uri url})? _justCreated;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _pickChannel() async {
    final store = await ref.read(storeProvider.future);
    final channels = await store.watchChannels().first;
    if (!mounted) return;
    final picked = await showAppSheet<Channel>(
      context,
      builder: (context) => ChannelPickerSheet(channels: channels),
    );
    if (picked == null) return;
    setState(() => _channel = picked);
  }

  Future<void> _create() async {
    final channel = _channel;
    final label = _label.text.trim();
    if (channel == null || label.isEmpty) return;
    setState(() => _busy = true);
    api.NewWebhook? created;
    final ok = await guard(
      whatFailed: 'create the webhook',
      action: () async {
        created = await ref.read(apiProvider).createWebhook(channel.id, label);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok && created != null) {
        _reveal(created!);
        _label.clear();
        _channel = null;
      }
    });
    if (ok) ref.invalidate(webhooksProvider);
  }

  void _reveal(api.NewWebhook created) {
    final url = ref.read(apiProvider).baseUrl.resolve(created.deliveryPath);
    setState(() => _justCreated = (created: created, url: url));
  }

  @override
  Widget build(BuildContext context) {
    final webhooks = ref.watch(webhooksProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_justCreated case final created?) ...[
          _UrlReveal(
            created: created.created,
            url: created.url,
            onDismiss: () => setState(() => _justCreated = null),
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        const SettingsSectionHeader(ActionLabels.createWebhook),
        SettingsSectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Channel',
              style: AppText.label.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            AppButton(
              label: _channel?.name ?? 'Choose a channel',
              variant: AppButtonVariant.secondary,
              icon: AppIcons.hash,
              onPressed: _pickChannel,
            ),
            const SizedBox(height: AppSpacing.s16),
            LabeledField(
              label: 'Label',
              helper: 'Shown in this list and beside its posts.',
              child: AppInput(
                controller: _label,
                semanticLabel: 'Webhook label',
                onSubmitted: (_) => _busy ? null : _create(),
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: ActionLabels.createWebhook,
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
        const SettingsSectionHeader('Webhooks in this Space'),
        AppAsyncView<List<api.Webhook>>(
          value: AppAsyncState(
            data: webhooks.valueOrNull,
            error: webhooks.error,
          ),
          center: false,
          errorMessage: 'Could not load the webhooks.',
          onRetry: () => ref.invalidate(webhooksProvider),
          isEmpty: (list) => list.isEmpty,
          emptyMessage: 'No webhooks yet.',
          data: (context, list) => SettingsSectionCard(
            children: [
              for (final webhook in list)
                _WebhookRow(webhook: webhook, onRotated: _reveal),
            ],
          ),
        ),
      ],
    );
  }
}

/// The created webhook's delivery URL, shown once.
class _UrlReveal extends StatelessWidget {
  const _UrlReveal({
    required this.created,
    required this.url,
    required this.onDismiss,
  });

  final api.NewWebhook created;
  final Uri url;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsNotice(
          icon: AppIcons.warning,
          message:
              'This is the only time ${created.webhook.label}\'s URL is '
              'shown. Copy it now - the server keeps only a hash of its '
              'token, so it cannot be shown again. Rotate it for a new one '
              'if you lose it.',
        ),
        const SizedBox(height: AppSpacing.s12),
        SelectableText(
          url.toString(),
          style: AppText.code,
          semanticsLabel: 'Webhook URL for ${created.webhook.label}',
        ),
        const SizedBox(height: AppSpacing.s12),
        Row(
          children: [
            AppButton(
              label: 'Copy URL',
              variant: AppButtonVariant.primary,
              size: AppButtonSize.sm,
              icon: AppIcons.copy,
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: url.toString())),
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

class _WebhookRow extends ConsumerStatefulWidget {
  const _WebhookRow({required this.webhook, required this.onRotated});

  final api.Webhook webhook;
  final ValueChanged<api.NewWebhook> onRotated;

  @override
  ConsumerState<_WebhookRow> createState() => _WebhookRowState();
}

class _WebhookRowState extends ConsumerState<_WebhookRow>
    with GuardedActionState<_WebhookRow> {
  bool _busy = false;

  Future<void> _revoke() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Revoke ${widget.webhook.label}?',
      message:
          'Its URL will stop accepting posts immediately. Anything already '
          'sent through it stays in the channel.',
      confirmLabel: 'Revoke',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'revoke ${widget.webhook.label}',
      action: () => ref.read(apiProvider).revokeWebhook(widget.webhook.id),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(webhooksProvider);
  }

  Future<void> _rotate() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Rotate ${widget.webhook.label}?',
      message:
          'Its current URL stops working immediately, and you will get a new '
          'one to paste into whatever was using it. What it already posted '
          'stays attributed to it.',
      confirmLabel: 'Rotate',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    api.NewWebhook? rotated;
    final ok = await guard(
      whatFailed: 'rotate ${widget.webhook.label}',
      action: () async {
        rotated = await ref.read(apiProvider).rotateWebhook(widget.webhook.id);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && rotated != null) widget.onRotated(rotated!);
    if (ok) ref.invalidate(webhooksProvider);
  }

  @override
  Widget build(BuildContext context) {
    final webhook = widget.webhook;
    return SettingsEntityRow(
      headline: webhook.label,
      details: [
        if (webhook.createdByDisplayName case final minter?)
          SettingsEntityDetail('Minted by $minter'),
        if (webhook.lastDeliveryAt case final at?)
          SettingsEntityDetail(webhookDeliveryLabel(at, DateTime.now()))
        else
          const SettingsAbsentValue('Never delivered yet.'),
      ],
      actions: [
        AppIconButton(
          icon: AppIcons.edit,
          semanticLabel: 'Rename ${webhook.label}',
          onPressed: () => showRenameWebhookSheet(context, webhook),
        ),
        AppIconButton(
          icon: AppIcons.retry,
          semanticLabel: 'Rotate ${webhook.label}',
          onPressed: _busy ? null : _rotate,
        ),
        AppIconButton(
          icon: AppIcons.revoke,
          semanticLabel: 'Revoke ${webhook.label}',
          variant: AppIconButtonVariant.danger,
          onPressed: _busy ? null : _revoke,
        ),
      ],
      error: actionError,
      onErrorDismiss: clearActionError,
    );
  }
}

/// "Last delivered 3h ago", so a silent integration reads as silent.
String webhookDeliveryLabel(int deliveredAtMs, DateTime now) {
  return 'Last delivered ${formatRelativeAgeMs(deliveredAtMs, now: now)}';
}

/// Opens the label editor for one webhook.
Future<void> showRenameWebhookSheet(BuildContext context, api.Webhook webhook) {
  return showAppSheet<void>(
    context,
    builder: (context) => _RenameWebhookSheet(webhook: webhook),
  );
}

class _RenameWebhookSheet extends ConsumerStatefulWidget {
  const _RenameWebhookSheet({required this.webhook});

  final api.Webhook webhook;

  @override
  ConsumerState<_RenameWebhookSheet> createState() =>
      _RenameWebhookSheetState();
}

class _RenameWebhookSheetState extends ConsumerState<_RenameWebhookSheet> {
  late final _label = TextEditingController(text: widget.webhook.label);
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final label = _label.text.trim();
    if (label.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).renameWebhook(widget.webhook.id, label);
      if (context.mounted) ref.invalidate(webhooksProvider);
      if (mounted) Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeApiFailure("rename ${widget.webhook.label}", e);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Rename ${widget.webhook.label}',
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(AppIcons.dismiss, color: tokens.textSecondary),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          AppInput(
            controller: _label,
            semanticLabel: 'Webhook label',
            onSubmitted: (_) => _submitting ? null : _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: _error!),
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
