// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A temporary room's own settings (decision 0065), for its owner or anyone
/// with MANAGE_CHANNELS: rename, lock, and a user limit. The lock and limit
/// save on change; the name saves on its button, like channel settings.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiVoiceRooms;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../preset_options.dart';
import '../providers/channel_by_id_provider.dart';
import '../providers/providers.dart';
import '../screens/channel_settings_rooms_section.dart'
    show userLimitLabel, userLimitOptions;
import '../entity_name.dart';
import 'run_guarded.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';

Future<void> showVoiceRoomSettingsSheet(
  BuildContext context, {
  required Channel room,
}) => showAppSheet<void>(
  context,
  builder: (context) => VoiceRoomSettingsSheet(room: room),
);

/// Whether [userId] may change [room]'s settings: its owner, or a holder of
/// the deployment-wide MANAGE_CHANNELS bit ([canManage]).
bool canEditRoom(Channel room, String? userId, {required bool canManage}) =>
    room.roomOwnerId != null && (room.roomOwnerId == userId || canManage);

class VoiceRoomSettingsSheet extends ConsumerStatefulWidget {
  const VoiceRoomSettingsSheet({required this.room, super.key});

  final Channel room;

  @override
  ConsumerState<VoiceRoomSettingsSheet> createState() =>
      _VoiceRoomSettingsSheetState();
}

class _VoiceRoomSettingsSheetState extends ConsumerState<VoiceRoomSettingsSheet>
    with GuardedActionState<VoiceRoomSettingsSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.room.name,
  );
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save({String? name, bool? locked, int? userLimit}) async {
    setState(() => _saving = true);
    await guard(
      whatFailed: 'change the room',
      action: () async {
        final updated = await ref
            .read(apiProvider)
            .updateVoiceRoom(
              channelId: widget.room.id,
              name: name,
              locked: locked,
              userLimit: userLimit,
            );
        final store = await ref.read(storeProvider.future);
        await store.upsertChannels([updated]);
      },
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final room =
        ref.watch(channelByIdProvider(widget.room.id)).valueOrNull ??
        widget.room;
    final limit = room.userLimit ?? 0;
    final options = presetsIncluding(userLimitOptions, limit, userLimitLabel);
    final trimmed = _name.text.trim();
    final canRename = !_saving && trimmed.isNotEmpty && trimmed != room.name;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Room settings', style: AppText.heading),
          const SizedBox(height: AppSpacing.s16),
          AppInput(
            counterMax: entityNameMaxChars,
            controller: _name,
            placeholder: 'Room name',
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) =>
                canRename ? unawaited(_save(name: trimmed)) : null,
            semanticLabel: 'Room name',
          ),
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            label: 'Rename',
            variant: AppButtonVariant.secondary,
            full: true,
            disabled: !canRename,
            onPressed: () => _save(name: trimmed),
          ),
          const SizedBox(height: AppSpacing.s12),
          SettingsToggleRow(
            label: 'Locked',
            description: 'Nobody new can join.',
            value: room.roomLocked ?? false,
            onChanged: _saving ? null : (v) => _save(locked: v),
            semanticLabel: 'Lock the room',
          ),
          SettingsSelectRow<int>(
            label: 'User limit',
            sheetTitle: 'User limit',
            value: limit,
            choices: [
              for (final option in options)
                SettingsChoice(value: option.$2, label: option.$1),
            ],
            sheetFootnote: 'The most people in the call at once.',
            onChanged: (value) => _saving ? null : _save(userLimit: value),
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: actionError!, onDismiss: clearActionError),
          ],
        ],
      ),
    );
  }
}
