// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel settings' Private toggle, for a channel that already exists: the
/// same `@everyone` deny and self grant the create sheet's toggle writes,
/// so making a channel private no longer means finding VIEW_CHANNEL in the
/// permissions grid by hand.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../providers/channel_by_id_provider.dart';
import '../../../providers/providers.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../../settings/widgets/settings_toggle_row.dart';

/// Denies `@everyone` the view of [channelId] and grants it to [selfId],
/// keeping every other bit both overwrites already carry.
Future<void> makeChannelPrivate(
  api.SlimmApi client, {
  required String channelId,
  required String everyoneRoleId,
  required String selfId,
}) async {
  final existing = await client.getChannelOverwrites(channelId);
  api.ChannelOverwrite? find(api.OverwriteTarget kind, String id) =>
      existing.where((o) => o.kind == kind && o.id == id).firstOrNull;
  final everyone = find(api.OverwriteTarget.role, everyoneRoleId);
  final self = find(api.OverwriteTarget.member, selfId);
  await client.batchSetChannelOverwrites(
    channelId: channelId,
    overwrites: [
      api.ChannelOverwriteEdit(
        kind: api.OverwriteTarget.member,
        id: selfId,
        allow: (self?.allow ?? 0) | Perm.viewChannel,
        deny: (self?.deny ?? 0) & ~Perm.viewChannel,
      ),
      api.ChannelOverwriteEdit(
        kind: api.OverwriteTarget.role,
        id: everyoneRoleId,
        allow: (everyone?.allow ?? 0) & ~Perm.viewChannel,
        deny: (everyone?.deny ?? 0) | Perm.viewChannel,
      ),
    ],
  );
}

/// Lifts `@everyone`'s view deny on [channelId], leaving its other bits and
/// every member's own grant alone.
Future<void> makeChannelPublic(
  api.SlimmApi client, {
  required String channelId,
  required String everyoneRoleId,
}) async {
  final everyone = (await client.getChannelOverwrites(channelId))
      .where(
        (o) => o.kind == api.OverwriteTarget.role && o.id == everyoneRoleId,
      )
      .firstOrNull;
  if (everyone == null) return;
  await client.batchSetChannelOverwrites(
    channelId: channelId,
    overwrites: [
      api.ChannelOverwriteEdit(
        kind: api.OverwriteTarget.role,
        id: everyoneRoleId,
        allow: everyone.allow,
        deny: everyone.deny & ~Perm.viewChannel,
      ),
    ],
  );
}

class ChannelPrivateRow extends ConsumerStatefulWidget {
  const ChannelPrivateRow({super.key, required this.channel});

  final Channel channel;

  @override
  ConsumerState<ChannelPrivateRow> createState() => _ChannelPrivateRowState();
}

class _ChannelPrivateRowState extends ConsumerState<ChannelPrivateRow>
    with GuardedActionState<ChannelPrivateRow> {
  bool? _optimistic;
  bool _saving = false;

  Future<void> _set(bool private) async {
    final name = widget.channel.name;
    if (private &&
        !await confirmDangerousAction(
          context,
          title: 'Make #$name private?',
          message:
              'Only you, administrators and anyone you add under '
              'Permissions will see it.',
          confirmLabel: 'Make private',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _optimistic = private;
    });
    final ok = await guard(
      whatFailed: private ? 'make the channel private' : 'make it public',
      action: () async {
        final client = ref.read(apiProvider);
        final roles = await client.listRoles();
        final everyone = roles.firstWhere((r) => r.isEveryone);
        final selfId = ref.read(sessionProvider).tokens!.userId;
        if (private) {
          await makeChannelPrivate(
            client,
            channelId: widget.channel.id,
            everyoneRoleId: everyone.id,
            selfId: selfId,
          );
        } else {
          await makeChannelPublic(
            client,
            channelId: widget.channel.id,
            everyoneRoleId: everyone.id,
          );
        }
        ref.invalidate(channelOverwritesProvider(widget.channel.id));
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
    // The save writes overwrites, not this row, so the tapped value stands until the row agrees.
    ref.listen(channelByIdProvider(widget.channel.id), (_, next) {
      final restricted = next.valueOrNull?.restricted;
      if (_optimistic != null && !_saving && restricted == _optimistic) {
        setState(() => _optimistic = null);
      }
    });
    final stored =
        ref.watch(channelByIdProvider(widget.channel.id)).valueOrNull ??
        widget.channel;
    final private = _optimistic ?? stored.restricted ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Private',
          description: 'Only people you add can see it.',
          value: private,
          semanticLabel: 'Private channel',
          onChanged: _saving ? null : (value) => unawaited(_set(value)),
        ),
        if (actionError != null)
          SettingsSaveFeedback(
            inCard: true,
            tick: 0,
            error: actionError,
            onDismissError: clearActionError,
          ),
      ],
    );
  }
}
