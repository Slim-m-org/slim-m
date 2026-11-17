// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The collapsed call strip: what a live call looks like on a phone once you
/// have navigated to a different channel.
///
/// Compact width has no rail to carry a call summary, so the shell pins this
/// strip above the bottom edge instead. A wider layout shows the same
/// information in the call row above the rail's user bar (`RailCallRow`)
/// rather than a second strip; this widget has no wide-layout rendering of
/// its own to keep in sync with that, since a rail is never absent above
/// `kCompactWidth`.
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

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../accounts/providers/account_providers.dart';
import '../../accounts/widgets/call_elsewhere_view.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../../../routing/routes.dart';
import '../screens/dm_call_pane.dart';
import 'call_participant_tiles.dart';
import 'call_strip_press_area.dart';
import '../../members/widgets/user_avatar.dart';

const _inCallLabel = 'In a call';

/// The strip's root, for tests to tell it from the rail's summary.
const voiceStripKey = Key('voice_strip');

/// Whether a call is live and worth surfacing, regardless of which channel is
/// on screen. The caller decides *where* it renders; this decides *if*. With no
/// call here, a call in another community shows the way the rail's row shows it.
class VoiceStripIndicator extends ConsumerWidget {
  const VoiceStripIndicator({super.key, this.atTop = false});

  /// Pinned above the transcript instead of below it, so the border flips.
  final bool atTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceFlagsProvider);
    if (!voice.callLive) {
      final elsewhere = ref.watch(accountsSnapshotProvider).callElsewhere;
      if (elsewhere == null) return const SizedBox.shrink();
      return CallElsewhereView(
        entry: elsewhere,
        builder: (context, call) => _CommunityStrip(call: call, atTop: atTop),
      );
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _StripFrame(
      atTop: atTop,
      press: switch (voice.channelId) {
        final channelId? => _ReturnToCall(
          voice: voice,
          onPressed: () => returnToCall(ref, context, channelId),
        ),
        null => null,
      },
      summary: _Summary(
        voice: voice,
        leading: const _FaceRow(),
        title: CallChannelName(
          channelId: voice.channelId,
          style: _Summary.titleStyle(tokens),
        ),
      ),
      controls: _Controls(
        voice: voice,
        controller: ref.read(voiceControllerProvider.notifier),
      ),
    );
  }
}

/// Another community's call: its glyph where the faces go, its name leading
/// the second line, and a press that switches there first.
class _CommunityStrip extends StatelessWidget {
  const _CommunityStrip({required this.call, required this.atTop});

  final CallElsewhere call;
  final bool atTop;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channel = call.channelName;
    return _StripFrame(
      atTop: atTop,
      press: CallStripPressArea(
        semanticLabel: call.returnLabel,
        onPressed: () => unawaited(call.open()),
      ),
      summary: _Summary(
        voice: call.voice,
        leading: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(
            AppIcons.voice,
            size: AppSizes.icon20,
            color: tokens.accent,
          ),
        ),
        title: Text(
          channel ?? _inCallLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _Summary.titleStyle(tokens),
        ),
        community: call.community,
      ),
      controls: _Controls(voice: call.voice, controller: call.controller),
    );
  }
}

/// The strip's fill and border, its press surface, and [summary] drawn over
/// that surface beside [controls].
class _StripFrame extends StatelessWidget {
  const _StripFrame({
    required this.atTop,
    required this.press,
    required this.summary,
    required this.controls,
  });

  final bool atTop;
  final Widget? press;
  final Widget summary;
  final Widget controls;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      key: voiceStripKey,
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
          if (press case final press?) Positioned.fill(child: press),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s8,
            ),
            child: Row(
              children: [
                Expanded(child: IgnorePointer(child: summary)),
                controls,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Back to the live call's channel; shared by every surface that collapses a call.
void returnToCall(WidgetRef ref, BuildContext context, String channelId) {
  // See RailCallSummary's identical line for why.
  ref.read(dmCallOpenProvider.notifier).state = channelId;
  context.go(Routes.channel(channelId));
}

/// The press surface, named for a screen reader as one button that carries the
/// channel; the ticking clock stays out of the label so nothing rebuilds per
/// second.
class _ReturnToCall extends ConsumerWidget {
  const _ReturnToCall({required this.voice, required this.onPressed});

  final VoiceFlags voice;
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

/// [leading], the channel name, clock and what the call is; drawn over the
/// press surface and left out of semantics, which the button's own label covers.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.voice,
    required this.leading,
    required this.title,
    this.community,
  });

  final VoiceFlags voice;
  final Widget leading;

  /// The channel's name, in [titleStyle].
  final Widget title;

  /// Leads the second line when the call is in another community.
  final String? community;

  static TextStyle titleStyle(AppTokens tokens) => AppText.caption.copyWith(
    color: tokens.textPrimary,
    fontWeight: AppWeights.medium,
  );

  static TextStyle _communityStyle(AppTokens tokens) =>
      AppText.caption.copyWith(color: tokens.textSecondary);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Row(
        children: [
          leading,
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                Row(
                  children: [
                    if (community case final name?) ...[
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textWidthBasis: TextWidthBasis.longestLine,
                          style: _communityStyle(tokens),
                        ),
                      ),
                      Text(' · ', style: _communityStyle(tokens)),
                    ],
                    if (voice.connectedAt case final since?)
                      CallDuration(since: since),
                    Flexible(
                      child: Text(
                        // Says what the call is, so no unseen share is a mystery.
                        _subtitle(
                          sharing: voice.screenSharing,
                          hasTimer: voice.connectedAt != null,
                          reconnecting: voice.rejoining || voice.reconnecting,
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

/// The first two people in this community's call.
class _FaceRow extends ConsumerWidget {
  const _FaceRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final faces = ref.watch(voiceParticipantsProvider.select(_Faces.of)).people;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (identity, name, speaking) in faces)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: UserAvatar(
              userId: identity,
              name: name,
              size: AppAvatarSize.s20,
              speaking: speaking,
            ),
          ),
      ],
    );
  }
}

/// The two avatars the strip draws, so only their changes rebuild it.
class _Faces {
  _Faces(this.people);

  factory _Faces.of(List<VoiceParticipant> all) =>
      _Faces([for (final p in all.take(2)) (p.identity, p.name, p.isSpeaking)]);

  final List<(String, String, bool)> people;

  @override
  bool operator ==(Object other) =>
      other is _Faces && listEquals(other.people, people);

  @override
  int get hashCode => Object.hashAll(people);
}

/// The separator only exists to sit after the timer; without one it would lead.
String _subtitle({
  required bool sharing,
  required bool hasTimer,
  required bool reconnecting,
}) {
  if (reconnecting) return hasTimer ? ' - reconnecting' : 'Reconnecting';
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

  final VoiceFlags voice;
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
