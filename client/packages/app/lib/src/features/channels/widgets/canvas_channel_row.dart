// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A canvas channel's rail row: the board's glyph and name, who has it open, and its call when one is live.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../routing/routes.dart';
import '../../canvas/providers/canvas_viewers.dart';
import '../../members/widgets/avatar_facepile.dart';
import '../../members/widgets/user_avatar.dart';
import '../../messages/providers/unread_indicator_rules.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/providers/voice_roster.dart';
import '../providers/channel_notification_overrides_controller.dart';
import 'channel_kind_icon.dart';
import 'channel_rail_channel_rows.dart' show voiceRosterAsParticipant;
import 'rail_call_length.dart';
import 'rail_participant_drag.dart';
import 'rail_voice_participants.dart';

const int _viewersShown = 3;
const int _viewersShownWithCall = 2;

/// Viewers who are not in the call, since the call's people are listed beneath the row.
@visibleForTesting
List<CanvasViewerPerson> viewersOutsideCall(
  List<CanvasViewerPerson> viewers,
  List<VoiceParticipant> call,
) {
  final inCall = {for (final p in call) p.identity};
  return [
    for (final v in viewers)
      if (!inCall.contains(v.id)) v,
  ];
}

/// "name, canvas channel", then the counts that are not zero.
@visibleForTesting
String canvasRowSemanticLabel(String name, {int viewing = 0, int inCall = 0}) =>
    [
      '$name, canvas channel',
      if (viewing > 0) '$viewing viewing',
      if (inCall > 0) '$inCall in the call',
    ].join(', ');

/// Tap opens the board and never joins its call; joining is the board bar's job.
class CanvasChannelRow extends ConsumerWidget {
  const CanvasChannelRow({
    super.key,
    required this.channel,
    required this.selected,
    this.trailingExtra,
  });

  final Channel channel;
  final bool selected;

  /// The kebab [ManagedChannelRow] hands down, revealed on hover in its own slot.
  final Widget? trailingExtra;

  List<VoiceParticipant> _call(WidgetRef ref, {required bool inCall}) {
    if (!channel.hostsCall) return const [];
    if (inCall) return ref.watch(voiceParticipantsProvider);
    return ref
            .watch(voiceRosterProvider(channel.id))
            .valueOrNull
            ?.map(voiceRosterAsParticipant)
            .toList(growable: false) ??
        const [];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (voiceState, voiceChannelId) = ref.watch(
      voiceFlagsProvider.select((f) => (f.state, f.channelId)),
    );
    final inCall =
        voiceState == VoiceSessionState.connected &&
        voiceChannelId == channel.id;
    final override = ref.watch(
      channelNotificationOverridesProvider.select(
        (s) => s.effectiveFor(channel),
      ),
    );
    final indicator = unreadIndicatorForChannel(
      channel,
      channelOverride: override,
      isDm: false,
    );
    final call = _call(ref, inCall: inCall);
    final live = call.isNotEmpty;
    final waiting = viewersOutsideCall(
      ref.watch(canvasViewerPeopleProvider(channel.id)),
      call,
    );
    final cap = live ? _viewersShownWithCall : _viewersShown;
    final shown = waiting.take(cap).toList(growable: false);
    final hasLength =
        (inCall
            ? ref.watch(voiceControllerProvider.select((v) => v.connectedAt))
            : ref.watch(voiceRosterStartProvider(channel.id))) !=
        null;
    final marks = [
      if (shown.isNotEmpty)
        ExcludeSemantics(
          child: AvatarFacepile(
            more: waiting.length - shown.length,
            avatars: [
              for (final v in shown)
                UserAvatar(
                  key: ValueKey(v.id),
                  name: v.name,
                  userId: v.id,
                  size: AppAvatarSize.s20,
                ),
            ],
          ),
        ),
      if (live && hasLength)
        RailCallLength(channelId: channel.id, inCall: inCall),
      if (indicator.unread || indicator.mentioned)
        AppListRow.indicatorDot(
          mentioned: indicator.mentioned,
          color: indicator.mentioned ? tokens.accentFill : tokens.textPrimary,
        ),
    ];
    final row = AppListRow(
      key: ValueKey('canvas-row-${channel.id}'),
      label: channel.name,
      semanticLabel: canvasRowSemanticLabel(
        channel.name,
        viewing: waiting.length,
        inCall: call.length,
      ),
      selected: selected,
      unread: indicator.unread,
      mentioned: indicator.mentioned,
      muted: override == api.NotificationPreference.nothing,
      leading: ChannelKindIcon(
        glyph: ChannelGlyphKind.canvas,
        restricted: channel.restricted ?? false,
        color: selected || inCall ? tokens.accent : tokens.textSecondary,
      ),
      trailing: marks.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s8,
              children: marks,
            ),
      trailingExtra: trailingExtra,
      revealTrailingExtraOnHover: true,
      onTap: () => context.go(Routes.channel(channel.id)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        channel.hostsCall
            ? RailMoveDropTarget(channelId: channel.id, child: row)
            : row,
        if (live)
          RailParticipantList(participants: call, channelId: channel.id),
      ],
    );
  }
}
