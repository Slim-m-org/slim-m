// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail footer's call row: back to a call live elsewhere, and Leave without
/// going there. See docs/decisions/0111-personal-space-is-called-notes.md.
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
      community: call.community,
      onOpen: call.open,
      onLeave: () => unawaited(call.controller.leave()),
    ),
  );
}

/// The call's speaker glyph over the avatar column, its channel and timer,
/// and Leave last, over the gear.
class _CallRow extends StatelessWidget {
  const _CallRow({
    required this.channelName,
    required this.voice,
    required this.onOpen,
    required this.onLeave,
    this.community,
  });

  final String? channelName;
  final VoiceFlags voice;
  final String? community;
  final Future<void> Function() onOpen;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      key: railCallRowKey,
      children: [
        // The avatar column's own width, so the glyph sits over the avatar.
        SizedBox(
          width: AppSizes.rowTouch,
          child: Icon(
            AppIcons.voice,
            size: AppSizes.icon20,
            color: tokens.accent,
          ),
        ),
        const SizedBox(width: 9),
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
        _OverGear(child: railLeaveCallButton(onLeave)),
      ],
    );
  }
}

/// Holds [child] in the gear's own footprint, so a dock chip, whose focus ring
/// keeps its gap outside the chip, still centres over the gear below it.
class _OverGear extends StatelessWidget {
  const _OverGear({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer,
    child: OverflowBox(
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      // The chip's hover fill is ink, which the footer's own fill would otherwise paint over.
      child: Material(type: MaterialType.transparency, child: child),
    ),
  );
}

/// The call's channel and duration, a tap target back to the call.
class RailCallSummary extends StatefulWidget {
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
  State<RailCallSummary> createState() => _RailCallSummaryState();
}

class _RailCallSummaryState extends State<RailCallSummary> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channelName = widget.channelName;
    final community = widget.community;

    return Tooltip(
      message: channelName == null ? 'Go to the call' : 'Go to $channelName',
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: [
          channelName == null
              ? 'Back to the call'
              : 'Back to the call in $channelName',
          ?community,
        ].join(', '),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: () {
              AppHaptics.selection();
              unawaited(widget.onOpen());
            },
            child: AnimatedOpacity(
              opacity: _pressed ? 0.6 : 1,
              duration: AppMotion.reduced(context, AppMotion.fast),
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
                    connectedAt: widget.connectedAt,
                    screenSharing: widget.screenSharing,
                  ),
                ],
              ),
            ),
          ),
        ),
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
            child: Text(
              ' - sharing',
              overflow: TextOverflow.ellipsis,
              style: AppText.micro.copyWith(color: tokens.accent),
            ),
          ),
      ],
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
