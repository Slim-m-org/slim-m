// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' join-muted section for a voice channel: saves through
/// `PATCH /channels/{id}` on tap, like `ChannelSlowModeSection`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `updateChannel` extension; `Channel` hidden to avoid `slimm_data`'s.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import '../providers/channel_by_id_provider.dart';
import '../../../providers/providers.dart';
import '../../../widgets/optimistic_setting_state.dart';
import '../../../widgets/run_guarded.dart';
import '../../../widgets/settings_toggle_row.dart';
import '../../../widgets/settings_save_feedback.dart';

class ChannelJoinMutedSection extends ConsumerStatefulWidget {
  const ChannelJoinMutedSection({super.key, required this.channel});

  final Channel channel;

  /// One toggle row inside another card instead of its own card.
  @override
  ConsumerState<ChannelJoinMutedSection> createState() =>
      _ChannelJoinMutedSectionState();
}

class _ChannelJoinMutedSectionState
    extends ConsumerState<ChannelJoinMutedSection>
    with
        GuardedActionState<ChannelJoinMutedSection>,
        OptimisticSettingState<ChannelJoinMutedSection, bool> {
  Future<void> _set(bool joinMuted) => saveOptimistic(
    joinMuted,
    whatFailed: 'change join muted',
    action: () async {
      final updated = await ref
          .read(apiProvider)
          .updateChannel(channelId: widget.channel.id, joinMuted: joinMuted);
      final store = await ref.read(storeProvider.future);
      await store.upsertChannels([updated]);
    },
    refresh: channelByIdProvider(widget.channel.id),
  );

  @override
  Widget build(BuildContext context) {
    final channel = channelByIdProvider(widget.channel.id);
    ref.listen(channel, (_, next) => retireOptimistic(next));
    // The stored row, so a save that landed earlier is what a later failure falls back to.
    final stored = ref.watch(channel).valueOrNull ?? widget.channel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Join muted',
          description: 'Members start with their mic off and can unmute.',
          value: shown(stored.joinMuted, false),
          onChanged: saving ? null : _set,
          semanticLabel: 'Members join this channel muted',
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
