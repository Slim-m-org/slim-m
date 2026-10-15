// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail footer's call-elsewhere row: a way back to a call live in a
/// channel other than the one currently on screen, plus a way to leave it
/// without navigating there first.
///
/// Its own file so `channel_rail_frame.dart` carries the footer's wiring
/// without also carrying this row's content.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/channel_by_id_provider.dart';
import '../routing/routes.dart';
import '../screens/dm_call_pane.dart';
import 'call_participant_tiles.dart';

/// The call's channel and duration, standing in for [RailUserFooter]'s
/// name line while a call elsewhere is live, so the footer stays one bar.
///
/// Leave is [railLeaveCallButton], placed in the footer's control row; mic and
/// deafen are the footer's own toggles and are not repeated here.
class RailCallSummary extends ConsumerStatefulWidget {
  const RailCallSummary({
    super.key,
    required this.channelId,
    required this.connectedAt,
    required this.screenSharing,
  });

  final String channelId;
  final DateTime? connectedAt;
  final bool screenSharing;

  @override
  ConsumerState<RailCallSummary> createState() => _RailCallSummaryState();
}

class _RailCallSummaryState extends ConsumerState<RailCallSummary> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channelName = ref
        .watch(channelByIdProvider(widget.channelId))
        .valueOrNull
        ?.name;
    final name = channelName ?? 'In a call';

    return Semantics(
      button: true,
      label: channelName == null
          ? 'Back to the call'
          : 'Back to the call in $channelName',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          AppHaptics.selection();
          // A no-op for a real voice channel; load-bearing for a DM.
          ref.read(dmCallOpenProvider.notifier).state = widget.channelId;
          context.go(Routes.channel(widget.channelId));
        },
        child: AnimatedOpacity(
          opacity: _pressed ? 0.6 : 1,
          duration: AppMotion.reduced(context, AppMotion.fast),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.medium,
                  height: 1.25,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.connectedAt case final since?)
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: CallDuration(since: since),
                      ),
                    ),
                  if (widget.screenSharing)
                    Flexible(
                      child: Text(
                        ' - sharing',
                        overflow: TextOverflow.ellipsis,
                        style: AppText.micro.copyWith(color: tokens.accent),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Leaves the call from the footer without navigating to it first.
Widget railLeaveCallButton(VoidCallback onLeave) => AppIconButton(
  icon: AppIcons.leaveCall,
  semanticLabel: 'Leave call',
  tooltip: 'Leave call',
  variant: AppIconButtonVariant.danger,
  // Instant: the in-call bar's own leave button asks nothing either.
  onPressed: onLeave,
);
