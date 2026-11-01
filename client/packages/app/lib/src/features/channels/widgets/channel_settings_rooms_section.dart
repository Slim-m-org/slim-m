// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' temporary-room rows for a voice channel (decision
/// 0065): whether it makes a room per person, and its user limit. Saves on
/// change through `PATCH /channels/{id}`, like `ChannelSlowModeSection`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unaliased for the `updateChannel` extension; `Channel` hidden to avoid `slimm_data`'s.
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_data/data.dart';

import '../../../preset_options.dart';
import '../providers/channel_by_id_provider.dart';
import '../../../widgets/optimistic_setting_state.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_hairline.dart';
import '../../settings/widgets/settings_select_row.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../providers/channel_actions.dart';

/// The user limits offered, 0 for none; the server takes 0 to 99.
const List<(String, int)> userLimitOptions = [
  ('No limit', 0),
  ('2', 2),
  ('3', 3),
  ('4', 4),
  ('5', 5),
  ('8', 8),
  ('10', 10),
  ('15', 15),
  ('25', 25),
];

String userLimitLabel(int limit) => limit == 0 ? 'No limit' : '$limit';

class ChannelRoomsSection extends ConsumerStatefulWidget {
  const ChannelRoomsSection({super.key, required this.channel});

  final Channel channel;

  @override
  ConsumerState<ChannelRoomsSection> createState() =>
      _ChannelRoomsSectionState();
}

class _ChannelRoomsSectionState extends ConsumerState<ChannelRoomsSection>
    with
        GuardedActionState<ChannelRoomsSection>,
        OptimisticSettingState<ChannelRoomsSection, _RoomSettings> {
  Future<void> _save(
    _RoomSettings current, {
    bool? createsRooms,
    int? userLimit,
  }) => saveOptimistic(
    (rooms: createsRooms ?? current.rooms, limit: userLimit ?? current.limit),
    whatFailed: 'change the room settings',
    action: () async {
      await ref
          .read(channelActionsProvider)
          .update(
            widget.channel.id,
            ChannelUpdate(createsRooms: createsRooms, userLimit: userLimit),
          );
    },
    refresh: channelByIdProvider(widget.channel.id),
  );

  @override
  Widget build(BuildContext context) {
    final channel = channelByIdProvider(widget.channel.id);
    ref.listen(channel, (_, next) => retireOptimistic(next));
    final stored = ref.watch(channel).valueOrNull ?? widget.channel;
    final current = shown(
      (rooms: stored.createsRooms ?? false, limit: stored.userLimit ?? 0),
      (rooms: false, limit: 0),
    );
    final limit = current.limit;
    final options = presetsIncluding(userLimitOptions, limit, userLimitLabel);
    final isRoom = stored.roomOwnerId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isRoom) ...[
          SettingsToggleRow(
            label: 'Room per person',
            description: 'Joining makes a voice room of your own.',
            value: current.rooms,
            onChanged: saving ? null : (v) => _save(current, createsRooms: v),
            semanticLabel: 'Joining makes each person a room of their own',
          ),
          const SettingsHairline(),
        ],
        SettingsSelectRow<int>(
          label: 'User limit',
          sheetTitle: 'User limit',
          value: limit,
          choices: [
            for (final option in options)
              SettingsChoice(value: option.$2, label: option.$1),
          ],
          sheetFootnote: 'The most people in the call at once.',
          onChanged: (value) =>
              saving ? null : _save(current, userLimit: value),
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

typedef _RoomSettings = ({bool rooms, int limit});
