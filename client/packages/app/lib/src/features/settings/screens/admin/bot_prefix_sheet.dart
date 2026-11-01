// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet that changes the prefix one bot answers to.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/labeled_field.dart';
import '../../../../widgets/run_guarded.dart';

/// Opens the prefix editor for [bot].
Future<void> showBotPrefixSheet(BuildContext context, api.Bot bot) {
  return showAppSheet<void>(
    context,
    builder: (context) => _BotPrefixSheet(bot: bot),
  );
}

class _BotPrefixSheet extends ConsumerStatefulWidget {
  const _BotPrefixSheet({required this.bot});

  final api.Bot bot;

  @override
  ConsumerState<_BotPrefixSheet> createState() => _BotPrefixSheetState();
}

class _BotPrefixSheetState extends ConsumerState<_BotPrefixSheet>
    with GuardedActionState<_BotPrefixSheet> {
  late final _prefix = TextEditingController(text: widget.bot.prefix ?? '');
  bool _submitting = false;

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final prefix = _prefix.text.trim();
    if (prefix.isEmpty || prefix == widget.bot.prefix) {
      Navigator.of(context).pop();
      return;
    }
    clearActionError();
    setState(() => _submitting = true);
    final ok = await guard(
      whatFailed: "change ${widget.bot.displayName}'s prefix",
      action: () =>
          ref.read(apiProvider).setBotPrefix(widget.bot.userId, prefix),
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _submitting = false);
      return;
    }
    ref.invalidate(botsProvider);
    ref.invalidate(suggestedBotPrefixProvider);
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
                  "${widget.bot.displayName}'s prefix",
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
          const SizedBox(height: AppSpacing.s8),
          LabeledField(
            label: 'Command prefix',
            helper: 'Bots can share one while their commands differ.',
            child: AppInput(
              maxLength: api.InputLimits.botPrefix,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
              controller: _prefix,
              autocorrect: false,
              mono: true,
              semanticLabel: 'Bot command prefix',
              onSubmitted: (_) => _submitting ? null : _submit(),
            ),
          ),
          Text(
            'Takes effect when the bot reconnects.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: actionError!),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: _submitting ? 'Saving...' : 'Save prefix',
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
