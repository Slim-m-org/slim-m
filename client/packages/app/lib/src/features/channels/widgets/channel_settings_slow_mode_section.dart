// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' slow-mode section: `PATCH /channels/{id}`
/// ([api.SlimmApiChannelAdmin.updateChannel]), the same route
/// `ChannelGeneralSection` saves name and topic through. Split into its own
/// section rather than folded into that one, the same way the danger zone is
/// its own file: one concern per section card. Saves on tap rather than
/// behind a separate Save button, the same optimistic-set shape
/// `_RetentionSection` (`admin/performance_screen.dart`) uses for its own
/// "off plus a few presets" control.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `updateChannel` extension method; `Channel` hidden since `slimm_data`'s own (this section's `channel` field type) would otherwise collide.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import '../../../preset_options.dart';
import '../providers/channel_by_id_provider.dart';
import '../../../providers/providers.dart';
import '../../../widgets/optimistic_setting_state.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../../settings/widgets/settings_save_feedback.dart';

/// The interval choices offered here, index-matched to the segmented
/// control below. Not the server's own full 0..21600 range
/// (`SLOW_MODE_MAX_SECONDS` in `channel_slow_mode.rs`) - a curated set of
/// common intervals, the same shape `_retentionDayOptions` uses for message
/// retention.
const List<(String, int)> slowModeOptions = [
  ('Off', 0),
  ('10s', 10),
  ('30s', 30),
  ('1m', 60),
  ('10m', 600),
];

/// Reads a stored interval the presets do not list, e.g. `5s` or `1h`.
String slowModeLabel(int seconds) {
  if (seconds >= 3600 && seconds % 3600 == 0) return '${seconds ~/ 3600}h';
  if (seconds >= 60 && seconds % 60 == 0) return '${seconds ~/ 60}m';
  if (seconds > 60) return '${seconds ~/ 60}m ${seconds % 60}s';
  return '${seconds}s';
}

class ChannelSlowModeSection extends ConsumerStatefulWidget {
  const ChannelSlowModeSection({super.key, required this.channel});

  final Channel channel;

  /// One select row inside another card instead of its own card.
  @override
  ConsumerState<ChannelSlowModeSection> createState() =>
      _ChannelSlowModeSectionState();
}

class _ChannelSlowModeSectionState extends ConsumerState<ChannelSlowModeSection>
    with
        GuardedActionState<ChannelSlowModeSection>,
        OptimisticSettingState<ChannelSlowModeSection, int> {
  Future<void> _setSeconds(int seconds) => saveOptimistic(
    seconds,
    whatFailed: 'change slow mode',
    action: () async {
      final updated = await ref
          .read(apiProvider)
          .updateChannel(
            channelId: widget.channel.id,
            slowModeSeconds: seconds,
          );
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
    final current = shown(stored.slowModeSeconds, 0);
    final options = presetsIncluding(slowModeOptions, current, slowModeLabel);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSelectRow<int>(
          label: 'Slow mode',
          description: 'How long a member waits between their own messages.',
          sheetTitle: 'Slow mode',
          value: current,
          choices: [
            for (final option in options)
              SettingsChoice(value: option.$2, label: option.$1),
          ],
          onChanged: (seconds) => saving ? null : _setSeconds(seconds),
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
