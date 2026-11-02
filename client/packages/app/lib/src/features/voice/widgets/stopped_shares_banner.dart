// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The way back to a share the viewer stopped watching while it is still live.
///
/// Stopping leaves no stage behind, so without this the only way back was
/// "Watch stream" on the sharer's own participant menu. A banner, not an
/// overlay: it pushes the stage down (docs/design/desktop-vs-mobile.md, rule 6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/share_watch.dart';
import '../providers/voice_flags.dart';

/// Past this many hidden shares the rows fold into one, so they cannot crowd out the stage.
const int kStoppedShareRowsMax = 2;

/// Sharers the viewer stopped watching who are still sharing.
///
/// A held sharer is skipped: direct play stands in for that share, and
/// watching it would clear the hold and switch the stand-in off.
List<VoiceParticipant> stoppedSharers(
  List<VoiceParticipant> participants,
  ShareWatchState watch,
) => [
  for (final p in participants)
    if (p.isScreenSharing &&
        watch.stopped.contains(p.identity) &&
        !watch.held.contains(p.identity))
      p,
];

class StoppedSharesBanner extends ConsumerWidget {
  const StoppedSharesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharers = stoppedSharers(
      ref.watch(voiceParticipantsProvider),
      ref.watch(shareWatchProvider),
    );
    if (sharers.isEmpty) return const SizedBox.shrink();
    final watch = ref.read(shareWatchProvider.notifier);
    final folded = sharers.length > kStoppedShareRowsMax;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: Column(
        spacing: AppSpacing.s8,
        children: [
          if (folded)
            _Row(
              text: '${sharers.length} shares are hidden',
              action: 'Watch all',
              onWatch: () =>
                  sharers.map((p) => p.identity).forEach(watch.watch),
            )
          else
            for (final p in sharers)
              _Row(
                text: p.isLocal ? 'You are sharing' : '${p.name} is sharing',
                action: 'Watch',
                onWatch: () => watch.watch(p.identity),
              ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.text, required this.action, required this.onWatch});

  final String text;
  final String action;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) => AppCallout(
    tone: AppCalloutTone.info,
    icon: AppIcons.tileHide,
    child: Row(
      children: [
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        AppButton(
          label: action,
          size: AppButtonSize.sm,
          variant: AppButtonVariant.soft,
          icon: AppIcons.preview,
          onPressed: onWatch,
        ),
      ],
    ),
  );
}
