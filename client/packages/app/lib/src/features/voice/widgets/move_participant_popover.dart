// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Move to..." destination list: every voice channel the caller may move
/// people into, anchored beside a pointer menu and a sheet on a phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import '../../channels/providers/channel_permissions.dart';
import '../../members/widgets/member_profile_popover.dart';
import '../providers/voice_roster.dart';

const double _width = 260;

/// Opens the destination list for [userId], currently in [fromChannelId].
Future<void> showMoveParticipantPopover(
  BuildContext anchor, {
  required String userId,
  required String name,
  required String fromChannelId,
}) {
  Widget body(BuildContext context) => MoveDestinations(
    userId: userId,
    name: name,
    fromChannelId: fromChannelId,
    onDone: () => Navigator.of(context).pop(),
  );

  if (MediaQuery.sizeOf(anchor).width < kCompactWidth) {
    return showAppSheet<void>(anchor, builder: body);
  }
  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  final origin = box == null || overlay == null
      ? Offset.zero
      : box.localToGlobal(Offset.zero, ancestor: overlay);
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, _) => AnchoredMemberPopover(
      origin: origin,
      anchorSize: box?.size ?? Size.zero,
      child: body(context),
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

/// Whether [channel] can take one more person, given who is in it now.
bool hasRoomFor(api.Channel channel, int present) =>
    channel.userLimit == 0 || present < channel.userLimit;

/// The voice channels [fromChannelId] can be moved to, in rail order.
List<api.Channel> moveTargets(List<api.Channel> all, String fromChannelId) => [
  for (final c in all)
    if (c.isVoice &&
        !c.isThread &&
        c.id != fromChannelId &&
        (c.permissions ?? 0).hasPermission(Perm.moveMembers))
      c,
];

class MoveDestinations extends ConsumerStatefulWidget {
  const MoveDestinations({
    super.key,
    required this.userId,
    required this.name,
    required this.fromChannelId,
    required this.onDone,
  });

  final String userId;
  final String name;
  final String fromChannelId;
  final VoidCallback onDone;

  @override
  ConsumerState<MoveDestinations> createState() => _MoveDestinationsState();
}

class _MoveDestinationsState extends ConsumerState<MoveDestinations> {
  String? _failure;

  Future<void> _move(api.Channel to) async {
    setState(() => _failure = null);
    final failure = await runGuarded(
      whatFailed: 'move ${widget.name} to ${to.name}',
      action: () => ref
          .read(apiProvider)
          .moveVoiceParticipant(widget.fromChannelId, widget.userId, to.id),
    );
    if (!mounted) return;
    if (failure == null) {
      widget.onDone();
    } else {
      setState(() => _failure = failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channels = ref.watch(myVisibleChannelsProvider);
    final targets = channels.valueOrNull == null
        ? const <api.Channel>[]
        : moveTargets(channels.value!, widget.fromChannelId);
    final children = <Widget>[
      AppMenuLabel('Move ${widget.name} to'),
      if (channels.isLoading)
        const Padding(
          padding: EdgeInsets.all(AppSpacing.s12),
          child: Center(child: AppSpinner(size: AppSpinnerSize.lg)),
        )
      else if (channels.hasError)
        const AppErrorState(message: 'Could not load the voice channels.')
      else if (targets.isEmpty)
        const AppMenuFootnote('No other voice channel to move them to.')
      else
        for (final channel in targets)
          _DestinationRow(
            channel: channel,
            onMove: () => unawaited(_move(channel)),
          ),
      if (_failure != null) AppErrorState(message: _failure!),
    ];
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    // Without explicit child nodes the menu merges every row into one label.
    final rows = [
      Semantics(
        container: true,
        explicitChildNodes: true,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ];
    return compact
        ? AppSheetMenu(width: _width, children: rows)
        : AppMenu(width: _width, children: rows);
  }
}

class _DestinationRow extends ConsumerWidget {
  const _DestinationRow({required this.channel, required this.onMove});

  final api.Channel channel;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final present =
        ref.watch(voiceRosterProvider(channel.id)).valueOrNull?.length ?? 0;
    final full = !hasRoomFor(channel, present);
    return AppMenuItem(
      label: channel.name,
      leading: AppIcons.voice,
      trailing: channel.userLimit == 0
          ? null
          : Text(full ? 'Full' : '$present/${channel.userLimit}'),
      onTap: full ? null : onMove,
    );
  }
}
