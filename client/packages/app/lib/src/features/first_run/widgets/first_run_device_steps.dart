// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last two setup steps: what to be told about, and what a call uses.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../providers/push_controller.dart';
import '../../settings/providers/notification_preference_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/widgets/audio_device_section.dart';

const _choices = <(api.NotificationPreference, String, String)>[
  (api.NotificationPreference.everything, 'All messages', 'Every new message.'),
  (
    api.NotificationPreference.mentions,
    'Mentions and direct messages',
    'Only when someone is talking to you.',
  ),
  (api.NotificationPreference.nothing, 'Nothing', 'No notifications at all.'),
];

class FirstRunNotificationsStep extends ConsumerWidget {
  const FirstRunNotificationsStep({
    super.key,
    required this.choice,
    required this.onChoice,
  });

  /// The member's pick, or null while they have not touched it.
  final api.NotificationPreference? choice;
  final ValueChanged<api.NotificationPreference> onChoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stored = ref.watch(notificationPreferenceProvider);
    if (stored.hasError && stored.error is api.NotFoundException) {
      return const _PermissionBlock();
    }
    final selected = choice ?? stored.valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: 'Notify me for',
          child: Column(
            spacing: AppSpacing.s8,
            children: [
              for (final (value, label, caption) in _choices)
                _ChoiceTile(
                  label: label,
                  caption: caption,
                  selected: selected == value,
                  onTap: () => onChoice(value),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s16),
        const _PermissionBlock(),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.caption,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String caption;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      semanticLabel: '$label. $caption',
      ringRadius: AppRadii.card,
      builder: (context, focused, hovered) => Container(
        constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s12,
        ),
        decoration: BoxDecoration(
          color: selected ? tokens.accentSoft : Colors.transparent,
          border: Border.all(
            color: selected ? tokens.accentFill : tokens.borderSubtle,
          ),
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Row(
          spacing: AppSpacing.s12,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                  Text(
                    caption,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) Icon(AppIcons.check, size: 20, color: tokens.accent),
          ],
        ),
      ),
    );
  }
}

/// The system permission, shown only where this device can be pushed to.
class _PermissionBlock extends ConsumerWidget {
  const _PermissionBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final status = ref.watch(pushControllerProvider);
    if (status == PushStatus.unsupportedPlatform ||
        status == PushStatus.notSignedIn) {
      return const SizedBox.shrink();
    }
    final on = status == PushStatus.registered;
    final blocked = status == PushStatus.registeredNotificationsBlocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s12,
      children: [
        Row(
          spacing: AppSpacing.s12,
          children: [
            Icon(
              on ? AppIcons.notificationsOn : AppIcons.notificationsOff,
              size: 20,
              color: on ? tokens.accent : tokens.textSecondary,
            ),
            Expanded(
              child: Text(
                on
                    ? 'This device will show notifications.'
                    : blocked
                    ? 'Blocked in system settings.'
                    : 'This device needs your permission to show them.',
                style: AppText.ui.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
        ),
        if (!on && !blocked)
          AppButton(
            label: 'Allow notifications',
            onPressed: () =>
                unawaited(ref.read(pushControllerProvider.notifier).register()),
          ),
      ],
    );
  }
}

class FirstRunVoiceStep extends ConsumerWidget {
  const FirstRunVoiceStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: const AudioDeviceSection(embedded: true),
        ),
        const SizedBox(height: AppSpacing.s16),
        const _LevelMeter(),
      ],
    );
  }
}

/// Reads the live level, which only exists while a call has the microphone open.
class _LevelMeter extends ConsumerWidget {
  const _LevelMeter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final inCall = ref.watch(
      voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
    );
    final level = inCall ? ref.watch(localMicLevelProvider) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.s8,
      children: [
        Text(
          'Your level',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        Semantics(
          label: 'Microphone level',
          value: '${(level * 100).round()} percent',
          child: ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.full),
              child: LinearProgressIndicator(
                value: level,
                minHeight: 8,
                color: tokens.accent,
                backgroundColor: tokens.borderSubtle,
              ),
            ),
          ),
        ),
        Text(
          inCall
              ? 'Say something to see it move.'
              : 'Join a voice channel to see your level here.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}
