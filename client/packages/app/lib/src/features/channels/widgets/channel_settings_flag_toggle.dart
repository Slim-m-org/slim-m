// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One on/off channel setting that saves on tap: the tapped value shows at once, and a failure rolls it back with the error on the row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `updateChannel` extension; `Channel` hidden to avoid `slimm_data`'s.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import '../../../widgets/optimistic_setting_state.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/channel_actions.dart';
import '../providers/channel_by_id_provider.dart';

class ChannelFlagToggle extends ConsumerStatefulWidget {
  const ChannelFlagToggle({
    super.key,
    required this.channel,
    required this.label,
    required this.description,
    required this.semanticLabel,
    required this.whatFailed,
    required this.read,
    required this.update,
  });

  final Channel channel;
  final String label;
  final String description;
  final String semanticLabel;
  final String whatFailed;

  /// The stored value of this flag on a channel row.
  final bool Function(Channel) read;

  /// The PATCH body that sets the flag.
  final ChannelUpdate Function(bool) update;

  @override
  ConsumerState<ChannelFlagToggle> createState() => _ChannelFlagToggleState();
}

class _ChannelFlagToggleState extends ConsumerState<ChannelFlagToggle>
    with
        GuardedActionState<ChannelFlagToggle>,
        OptimisticSettingState<ChannelFlagToggle, bool> {
  Future<void> _set(bool value) => saveOptimistic(
    value,
    whatFailed: widget.whatFailed,
    action: () async {
      await ref
          .read(channelActionsProvider)
          .update(widget.channel.id, widget.update(value));
    },
    refresh: channelByIdProvider(widget.channel.id),
  );

  @override
  Widget build(BuildContext context) {
    final channel = channelByIdProvider(widget.channel.id);
    ref.listen(channel, (_, next) => retireOptimistic(next));
    final stored = ref.watch(channel).valueOrNull ?? widget.channel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: widget.label,
          description: widget.description,
          value: shown(widget.read(stored), false),
          onChanged: saving ? null : _set,
          semanticLabel: widget.semanticLabel,
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
