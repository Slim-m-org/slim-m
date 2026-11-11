// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The prompts shown before a join that would end or move another call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/providers/channel_by_id_provider.dart';

/// Shown instead of an automatic join when the caller is already connected
/// (or connecting) somewhere else: switching has to leave that call, so it
/// asks first rather than silently moving them, the one place a voice
/// channel arrival still needs an explicit decision.
class VoiceSwitchPrompt extends StatelessWidget {
  const VoiceSwitchPrompt({super.key, required this.onSwitch});

  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) => _VoicePrompt(
    title: 'Already in a call',
    message:
        "You're in a call somewhere else. Switching leaves it and "
        'joins this one instead.',
    confirmLabel: 'Switch to this call',
    onConfirm: onSwitch,
  );
}

/// Shown before a join that would move a call open on another device here.
class VoiceJoinHerePrompt extends ConsumerWidget {
  const VoiceJoinHerePrompt({
    super.key,
    required this.elsewhereChannelId,
    required this.onJoin,
    required this.onCancel,
  });

  final String elsewhereChannelId;
  final VoidCallback onJoin;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelByIdProvider(elsewhereChannelId));
    final name = channel.valueOrNull?.name;
    final where = name == null || name.isEmpty ? 'a call' : name;
    return _VoicePrompt(
      title: 'In a call on another device',
      message:
          "You're in $where on another device. Joining here moves your "
          'call to this device.',
      confirmLabel: 'Join here',
      onConfirm: onJoin,
      cancelLabel: 'Cancel',
      onCancel: onCancel,
    );
  }
}

class _VoicePrompt extends StatelessWidget {
  const _VoicePrompt({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel,
    this.onCancel,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final String? cancelLabel;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppBreathingHalo(
                child: Icon(
                  AppIcons.voice,
                  size: AppSizes.icon32,
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.s16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppText.heading.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s16),
              FilledButton(
                onPressed: onConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.accentFill,
                  foregroundColor: tokens.accentOn,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s16),
                ),
                child: Text(confirmLabel),
              ),
              if (cancelLabel != null) ...[
                const SizedBox(height: AppSpacing.s8),
                TextButton(onPressed: onCancel, child: Text(cancelLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
