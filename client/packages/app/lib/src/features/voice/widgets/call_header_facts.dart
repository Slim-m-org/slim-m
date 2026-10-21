// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's identity strip: where it is, which mode, how many and how long.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/voice_controller.dart';
import 'call_participant_tiles.dart';

/// Channel name, then [mode] when the canvas is open, then count and timer.
///
/// Both the call stage and the canvas pane draw this, so a call reads the same
/// wherever it is shown. Count and timer are micro mono with tabular figures
/// so the digits do not move as the timer runs.
class CallHeaderLine extends ConsumerWidget {
  const CallHeaderLine({
    super.key,
    required this.channelId,
    this.mode,
    this.leading,
    this.stacked = false,
    this.showTitle = true,
  });

  /// False where the channel's name already sits in a header above.
  final bool showTitle;

  /// The facts under the title rather than beside it, where a row of
  /// controls leaves the title too little width for both.
  final bool stacked;

  final String channelId;
  final String? mode;
  final Widget? leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final voice = ref.watch(voiceControllerProvider);
    final name = ref.watch(channelByIdProvider(channelId)).valueOrNull?.name;
    final inThisCall = voice.channelId == channelId;
    final title = [if (name != null && name.isNotEmpty) name, ?mode].join(', ');
    final facts = AppText.micro.copyWith(
      color: tokens.textSecondary,
      fontFamily: AppFonts.mono,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final titleText = Semantics(
      container: true,
      header: true,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(
          color: tokens.textPrimary,
          fontWeight: AppWeights.medium,
        ),
      ),
    );
    final live = inThisCall && voice.state == VoiceSessionState.connected;
    final factsRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${voice.participants.length} in call', style: facts),
        if (voice.connectedAt != null) ...[
          Text(' · ', style: facts),
          CallDuration(since: voice.connectedAt!, style: facts),
        ],
      ],
    );
    if (!showTitle) return live ? factsRow : const SizedBox.shrink();
    if (stacked) {
      return Row(
        children: [
          ?leading,
          Expanded(
            // Scales down rather than overflowing the bar at large text sizes.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [titleText, if (live) factsRow],
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        ?leading,
        Flexible(child: titleText),
        if (live) ...[const SizedBox(width: AppSpacing.s12), factsRow],
      ],
    );
  }
}
