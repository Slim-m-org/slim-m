// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How long a voice channel's call has been running, beside its rail row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_roster.dart';
import '../../voice/widgets/call_participant_tiles.dart';

/// The joined call counts from this device's own clock (the server's age once
/// it lands); any other channel counts from the server's last roster answer.
class RailCallLength extends ConsumerWidget {
  const RailCallLength({
    super.key,
    required this.channelId,
    required this.inCall,
  });

  final String channelId;
  final bool inCall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final since = inCall
        ? ref.watch(voiceControllerProvider.select((v) => v.connectedAt))
        : ref.watch(voiceRosterStartProvider(channelId));
    if (since == null) return const SizedBox.shrink();
    return CallDuration(
      since: since,
      style: AppText.micro.copyWith(
        color: tokens.textSecondary,
        fontFamily: AppFonts.mono,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
