// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' join-muted section for a voice channel: saves through
/// `PATCH /channels/{id}` on tap, like `ChannelSlowModeSection`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `updateChannel` extension; `Channel` hidden to avoid `slimm_data`'s.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_by_id_provider.dart';
import '../providers/providers.dart';
import '../widgets/run_guarded.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/settings_toggle_row.dart';
import '../widgets/success_flash.dart';

class ChannelJoinMutedSection extends ConsumerStatefulWidget {
  const ChannelJoinMutedSection({super.key, required this.channel});

  final Channel channel;

  @override
  ConsumerState<ChannelJoinMutedSection> createState() =>
      _ChannelJoinMutedSectionState();
}

class _ChannelJoinMutedSectionState
    extends ConsumerState<ChannelJoinMutedSection>
    with GuardedActionState<ChannelJoinMutedSection> {
  bool _saving = false;
  bool? _optimistic;

  Future<void> _set(bool joinMuted) async {
    setState(() {
      _saving = true;
      _optimistic = joinMuted;
    });
    final ok = await guard(
      whatFailed: 'change join muted',
      action: () async {
        final updated = await ref
            .read(apiProvider)
            .updateChannel(channelId: widget.channel.id, joinMuted: joinMuted);
        final store = await ref.read(storeProvider.future);
        await store.upsertChannels([updated]);
      },
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _optimistic = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The stored row, so a save that landed earlier is what a later failure falls back to.
    final stored =
        ref.watch(channelByIdProvider(widget.channel.id)).valueOrNull ??
        widget.channel;
    return SettingsSectionCard(
      title: 'Voice',
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Join muted',
          description: 'Members start with their mic off and can unmute.',
          value: _optimistic ?? stored.joinMuted,
          onChanged: _saving ? null : _set,
          semanticLabel: 'Members join this channel muted',
        ),
        SuccessFlash(tick: successTick),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
