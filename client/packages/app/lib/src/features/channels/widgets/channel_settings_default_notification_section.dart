// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' default-notifications row: saves through
/// `PATCH /channels/{id}` on tap, like `ChannelSlowModeSection`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `updateChannel` extension; `Channel` hidden to avoid `slimm_data`'s.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import '../providers/channel_by_id_provider.dart';
import '../../../widgets/optimistic_setting_state.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../../settings/widgets/settings_select_row.dart';
import 'channel_default_notification_choices.dart';
import '../providers/channel_actions.dart';

class ChannelDefaultNotificationSection extends ConsumerStatefulWidget {
  const ChannelDefaultNotificationSection({super.key, required this.channel});

  final Channel channel;

  /// One select row inside another card instead of its own card.
  @override
  ConsumerState<ChannelDefaultNotificationSection> createState() =>
      _ChannelDefaultNotificationSectionState();
}

class _ChannelDefaultNotificationSectionState
    extends ConsumerState<ChannelDefaultNotificationSection>
    with
        GuardedActionState<ChannelDefaultNotificationSection>,
        OptimisticSettingState<
          ChannelDefaultNotificationSection,
          NotificationPreference
        > {
  Future<void> _set(NotificationPreference level) => saveOptimistic(
    level,
    whatFailed: 'change the default notifications',
    action: () async {
      await ref
          .read(channelActionsProvider)
          .update(widget.channel.id, ChannelUpdate(defaultNotification: level));
    },
    refresh: channelByIdProvider(widget.channel.id),
  );

  @override
  Widget build(BuildContext context) {
    final channel = channelByIdProvider(widget.channel.id);
    ref.listen(channel, (_, next) => retireOptimistic(next));
    // The stored row, so a save that landed earlier is what a later failure falls back to.
    final stored = ref.watch(channel).valueOrNull ?? widget.channel;
    final current = shown(
      NotificationPreference.parse(stored.defaultNotification ?? 'everything'),
      NotificationPreference.everything,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSelectRow<NotificationPreference>(
          label: channelDefaultNotificationLabel,
          description: channelDefaultNotificationHint,
          sheetTitle: channelDefaultNotificationLabel,
          value: current,
          choices: channelDefaultNotificationChoices,
          onChanged: (level) => saving ? null : _set(level),
        ),
        SettingsSaveFeedback(
          inCard: true,
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }
}
