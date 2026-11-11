// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notifications step: first the system permission on a phone, then what
/// to be told about.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../settings/providers/notification_preference_controller.dart';
import '../../settings/widgets/settings_section_header.dart';

const _choices = <(api.NotificationPreference, String, String)>[
  (api.NotificationPreference.everything, 'All messages', 'Every new message.'),
  (
    api.NotificationPreference.mentions,
    'Mentions and direct messages',
    'Only when someone is talking to you.',
  ),
  (api.NotificationPreference.nothing, 'Nothing', 'No notifications at all.'),
];

/// Asks for the OS permission; the flow's own buttons answer it.
class FirstRunPermissionAsk extends StatelessWidget {
  const FirstRunPermissionAsk({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      topGap: kDenseSectionTopGap,
      children: [
        SettingsCardBlock(
          children: [
            Row(
              spacing: AppSpacing.s12,
              children: [
                Icon(AppIcons.notificationsOn, size: 24, color: tokens.accent),
                Expanded(
                  child: Text(
                    'Hear about messages when the app is closed.',
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                ),
              ],
            ),
            Text(
              'Your phone will ask once. If you say no, you will not be '
              'notified, and you can turn it on later in Settings.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ],
    );
  }
}

/// The level choice. Where the server has no setting to save it says so.
class FirstRunLevelStep extends ConsumerWidget {
  const FirstRunLevelStep({
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
    final selected = choice ?? stored.valueOrNull;
    final unavailable =
        stored.hasError && stored.error is api.NotFoundException;
    return SettingsSectionCard(
      title: 'Notify me for',
      topGap: kDenseSectionTopGap,
      children: [
        if (unavailable)
          const SettingsCardBlock(
            children: [Text('This Space has no notification levels to set.')],
          )
        else
          for (final (value, label, caption) in _choices)
            _LevelRow(
              label: label,
              caption: caption,
              selected: selected == value,
              onTap: () => onChoice(value),
            ),
      ],
    );
  }
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({
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
        color: selected ? tokens.accentSoft : Colors.transparent,
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
