// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail footer's call bar: back to a call live elsewhere, and its mute,
/// deafen, screen share and Leave without going there. See
/// docs/decisions/0111-personal-space-is-called-notes.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/channel_by_id_provider.dart';
import '../../accounts/providers/account_providers.dart';
import '../../accounts/widgets/call_elsewhere_view.dart';
import '../../../routing/routes.dart';
import '../../../widgets/shortcut_label.dart';
import '../../voice/providers/dm_call.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/widgets/call_dock_button.dart';
import '../../voice/widgets/call_participant_tiles.dart';
import 'rail_call_share_button.dart';
import 'rail_footer_controls.dart';
import 'rail_footer_press_target.dart';

/// The summary's root, for tests to find it without matching its type.
const railCallSummaryKey = Key('rail_call_summary');

/// The call row's own root.
const railCallRowKey = Key('rail_call_row');

/// The call row for this community's own call.
class RailCallRow extends ConsumerWidget {
  const RailCallRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceFlagsProvider);
    final channelId = voice.channelId;
    if (channelId == null) return const SizedBox.shrink();
    return _CallRow(
      channelName: ref.watch(channelByIdProvider(channelId)).valueOrNull?.name,
      voice: voice,
      controller: ref.read(voiceControllerProvider.notifier),
      onOpen: () async {
        // A no-op for a real voice channel; load-bearing for a DM.
        ref.read(dmCallOpenProvider.notifier).state = channelId;
        context.go(Routes.channel(channelId));
      },
      onLeave: () =>
          unawaited(ref.read(voiceControllerProvider.notifier).leave()),
    );
  }
}

/// The call row for [entry]'s call while another community is on screen: its
/// name leads the second line, a tap switches to it first, and the pill hides.
class RailCommunityCallRow extends StatelessWidget {
  const RailCommunityCallRow({super.key, required this.entry});

  final AccountEntry entry;

  @override
  Widget build(BuildContext context) => CallElsewhereView(
    entry: entry,
    builder: (context, call) => _CallRow(
      channelName: call.channelName,
      voice: call.voice,
      controller: call.controller,
      otherAccount: entry.container,
      community: call.community,
      onOpen: call.open,
      onLeave: () => unawaited(call.controller.leave()),
    ),
  );
}

/// The call's channel and timer, then its mic, deafen, share and Leave.
class _CallRow extends StatelessWidget {
  const _CallRow({
    required this.channelName,
    required this.voice,
    required this.controller,
    required this.onOpen,
    required this.onLeave,
    this.community,
    this.otherAccount,
  });

  final String? channelName;
  final VoiceFlags voice;
  final VoiceController controller;
  final String? community;

  /// The container of the community holding the call, when it is not on screen.
  final ProviderContainer? otherAccount;
  final Future<void> Function() onOpen;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: railCallRowKey,
      children: [
        Expanded(
          child: RailCallSummary(
            key: railCallSummaryKey,
            channelName: channelName,
            connectedAt: voice.connectedAt,
            screenSharing: voice.screenSharing,
            community: community,
            onOpen: onOpen,
          ),
        ),
        RailVoiceToggles(otherAccount: otherAccount),
        RailCallShareButton(
          voice: voice,
          controller: controller,
          ownAccount: otherAccount == null,
        ),
        // The chip's hover fill is ink, which the footer's own fill would otherwise paint over.
        Material(
          type: MaterialType.transparency,
          child: railLeaveCallButton(onLeave),
        ),
      ],
    );
  }
}

/// The call's channel and duration, a tap target back to the call.
class RailCallSummary extends StatelessWidget {
  const RailCallSummary({
    super.key,
    required this.channelName,
    required this.connectedAt,
    required this.screenSharing,
    required this.onOpen,
    this.community,
  });

  /// Null until the channel's row has loaded, which reads "In a call".
  final String? channelName;
  final DateTime? connectedAt;
  final bool screenSharing;
  final String? community;
  final Future<void> Function() onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channelName = this.channelName;
    final community = this.community;

    return RailFooterPressTarget(
      tooltip: channelName == null ? 'Go to the call' : 'Go to $channelName',
      semanticLabel: [
        channelName == null
            ? 'Back to the call'
            : 'Back to the call in $channelName',
        ?community,
      ].join(', '),
      onPressed: () => unawaited(onOpen()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            channelName ?? 'In a call',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.medium,
              height: 1.25,
            ),
          ),
          _SecondLine(
            community: community,
            connectedAt: connectedAt,
            screenSharing: screenSharing,
          ),
        ],
      ),
    );
  }
}

/// The community (when it is not the one on screen), the timer and sharing.
class _SecondLine extends StatelessWidget {
  const _SecondLine({
    required this.community,
    required this.connectedAt,
    required this.screenSharing,
  });

  final String? community;
  final DateTime? connectedAt;
  final bool screenSharing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (community case final name?) ...[
          Flexible(
            flex: 3,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textWidthBasis: TextWidthBasis.longestLine,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          // Outside the name, so a long one keeps its separator from the timer.
          Text(
            ' · ',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
        if (connectedAt case final since?)
          Flexible(
            flex: 2,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: CallDuration(since: since),
            ),
          ),
        if (screenSharing)
          Flexible(
            child: _WholeOrAbsent(
              text: ' - sharing',
              style: AppText.micro.copyWith(color: tokens.accent),
            ),
          ),
      ],
    );
  }
}

/// [text] drawn only when all of it fits the room left, never as a stub.
class _WholeOrAbsent extends StatelessWidget {
  const _WholeOrAbsent({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, room) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final fits = painter.width <= room.maxWidth;
        painter.dispose();
        return fits ? Text(text, maxLines: 1, style: style) : const SizedBox();
      },
    );
  }
}

/// Leaves the call from the rail without going there first: the dock's own
/// Leave (decision 0047 point 2), at the footer's icon size so it sits over the gear.
Widget railLeaveCallButton(VoidCallback onLeave) => CallDockButton(
  icon: AppIcons.leaveCall,
  semanticLabel: 'Leave call',
  tooltip: labelWithShortcut('Leave call', AppAction.leaveCall),
  active: false,
  destructive: true,
  heavyOutline: true,
  visualSize: AppSizes.icon28,
  iconSize: AppSizes.icon20,
  // Instant: the in-call bar's own leave button asks nothing either.
  onPressed: onLeave,
);
