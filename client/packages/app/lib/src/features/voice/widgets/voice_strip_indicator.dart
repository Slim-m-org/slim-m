// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The collapsed call strip: what a live call looks like on a phone once you
/// have navigated to a different channel.
///
/// Compact width has no rail to carry a call summary, so the shell pins this
/// strip above the bottom edge instead. A wider layout folds the same
/// information into the rail's own footer (`RailCallSummary`) rather than a
/// second strip; this widget has no wide-layout rendering of its own to keep
/// in sync with that, since a rail is never absent above `kCompactWidth`.
///
/// Its own file so the shell can show it without a screens-to-widgets import
/// running backwards.
///
/// The whole strip is one button back to the call (`docs/design/desktop-vs-mobile.md`
/// rule 6, a status banner that is also a way back); mute, deafen and leave are
/// the only controls that act on their own.
///
/// The design's "Open canvas" button is deliberately absent: the Voice Canvas
/// is Phase 6 and there is nothing to open, and a button that does nothing is
/// worse than a missing one. Everything else here acts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/voice_controller.dart';
import '../../../routing/routes.dart';
import '../screens/dm_call_pane.dart';
import 'call_participant_tiles.dart';
import 'call_strip_press_area.dart';
import '../../members/widgets/user_avatar.dart';

const _inCallLabel = 'In a call';

/// Whether a call is live and worth surfacing, regardless of which channel is
/// on screen. The caller decides *where* it renders; this decides *if*.
class VoiceStripIndicator extends ConsumerWidget {
  const VoiceStripIndicator({super.key, this.atTop = false});

  /// Pinned above the transcript instead of below it, so the border flips.
  final bool atTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceControllerProvider);
    if (voice.state != VoiceSessionState.connected) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final controller = ref.read(voiceControllerProvider.notifier);

    return Container(
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border(
          top: atTop ? BorderSide.none : BorderSide(color: tokens.borderSubtle),
          bottom: atTop
              ? BorderSide(color: tokens.borderSubtle)
              : BorderSide.none,
        ),
      ),
      constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
      child: Stack(
        children: [
          if (voice.channelId case final channelId?)
            Positioned.fill(
              child: _ReturnToCall(
                voice: voice,
                onPressed: () {
                  // See RailCallSummary's identical line for why.
                  ref.read(dmCallOpenProvider.notifier).state = channelId;
                  context.go(Routes.channel(channelId));
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: IgnorePointer(child: _Summary(voice: voice)),
                ),
                _Controls(voice: voice, controller: controller),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The press surface, named for a screen reader as one button that carries the
/// channel; the ticking clock stays out of the label so nothing rebuilds per
/// second.
class _ReturnToCall extends ConsumerWidget {
  const _ReturnToCall({required this.voice, required this.onPressed});

  final VoiceState voice;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = voice.channelId;
    final name =
        (id == null
            ? null
            : ref.watch(channelByIdProvider(id)).valueOrNull?.name) ??
        _inCallLabel;
    return CallStripPressArea(
      semanticLabel: 'Return to call, $name',
      onPressed: onPressed,
    );
  }
}

/// Avatars, channel name, clock and what the call is; drawn over the press
/// surface and left out of semantics, which the button's own label covers.
class _Summary extends StatelessWidget {
  const _Summary({required this.voice});

  final VoiceState voice;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Row(
        children: [
          for (final p in voice.participants.take(2))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: UserAvatar(
                userId: p.identity,
                name: p.name,
                size: AppAvatarSize.s20,
                speaking: p.isSpeaking,
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                CallChannelName(
                  channelId: voice.channelId,
                  style: AppText.caption.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
                Row(
                  children: [
                    if (voice.connectedAt case final since?)
                      CallDuration(since: since),
                    Flexible(
                      child: Text(
                        // Says what the call is, so no unseen share is a mystery.
                        _subtitle(
                          sharing: voice.screenSharing,
                          hasTimer: voice.connectedAt != null,
                        ),
                        overflow: TextOverflow.ellipsis,
                        style: AppText.micro.copyWith(
                          color: voice.screenSharing
                              ? tokens.accent
                              : tokens.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The separator only exists to sit after the timer; without one it would lead.
String _subtitle({required bool sharing, required bool hasTimer}) {
  if (hasTimer) return sharing ? ' - sharing' : ' - audio only';
  return sharing ? 'Sharing' : 'Audio only';
}

/// The channel a call is in, read from the local store rather than passed in:
/// callers include this strip and the rail's own call-elsewhere row
/// (`RailCallSummary`), and neither holds a channel name for a channel it is
/// not currently showing.
class CallChannelName extends ConsumerWidget {
  const CallChannelName({
    super.key,
    required this.channelId,
    required this.style,
  });

  final String? channelId;
  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = channelId;
    if (id == null) return Text(_inCallLabel, style: style);

    final name = ref.watch(channelByIdProvider(id)).valueOrNull?.name;
    return Text(
      name ?? _inCallLabel,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

/// Mic, deafen and leave.
///
/// Screen share is deliberately not here: the picker it opens needs room the
/// strip does not have, and the call screen one tap away has the button
/// already.
class _Controls extends StatelessWidget {
  const _Controls({required this.voice, required this.controller});

  final VoiceState voice;
  final VoiceController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AppIconButton(
          icon: voice.microphoneEnabled ? AppIcons.mic : AppIcons.micOff,
          semanticLabel: voice.microphoneEnabled ? 'Mute' : 'Unmute',
          tooltip: voice.microphoneEnabled ? 'Mute' : 'Unmute',
          onPressed: controller.toggleMicrophone,
        ),
        AppIconButton(
          icon: voice.deafened ? AppIcons.speakerOff : AppIcons.headphones,
          semanticLabel: voice.deafened ? 'Undeafen' : 'Deafen',
          tooltip: voice.deafened ? 'Undeafen' : 'Deafen',
          onPressed: controller.toggleDeafen,
        ),
        AppIconButton(
          icon: AppIcons.leaveCall,
          semanticLabel: 'Leave call',
          tooltip: 'Leave call',
          variant: AppIconButtonVariant.danger,
          onPressed: controller.leave,
        ),
      ],
    );
  }
}
