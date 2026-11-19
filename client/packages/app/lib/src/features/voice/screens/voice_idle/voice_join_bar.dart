// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-row join bar at the top of an idle voice channel (design 13):
/// what is true right now - who is here, who is online - and a button that
/// says what it does. Join muted is the primary one, so nothing is sent until
/// you unmute; a plain Join sits beside it unless the channel joins muted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../channels/providers/channel_by_id_provider.dart';
import '../../../members/providers/member_presence.dart';
import '../../../members/providers/presence_view.dart';
import '../../../../providers/providers.dart';
import '../../providers/voice_roster.dart';
import 'call_history_rows.dart' show callDayLabel;

class VoiceJoinBar extends ConsumerWidget {
  const VoiceJoinBar({
    super.key,
    required this.channelId,
    required this.compact,
    required this.lastCallAt,
    required this.now,
    required this.onJoin,
    this.onJoinWithMic,
    this.errorMessage,
    this.canRetry = true,
    this.rejoin = false,
  });

  /// The person just left this call, so the button says Rejoin.
  final bool rejoin;

  final String channelId;
  final bool compact;
  final int? lastCallAt;
  final int now;

  /// Joins muted.
  final VoidCallback onJoin;

  /// Joins with the mic as the person left it; null offers only [onJoin].
  final VoidCallback? onJoinWithMic;
  final String? errorMessage;
  final bool canRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final roster = ref.watch(voiceRosterProvider(channelId));
    final here = roster.valueOrNull ?? const [];
    final online = _online(ref, {for (final p in here) p.userId});
    final title = voiceRosterTitle(roster, compact: compact);
    final joinsMuted =
        ref.watch(channelByIdProvider(channelId)).valueOrNull?.joinMuted ??
        false;
    final withMic = errorMessage == null && !joinsMuted ? onJoinWithMic : null;
    final subtitle = _subtitle(here, online, mutedOnly: withMic == null);
    final buttons = errorMessage == null || canRetry
        ? _buttons(here, withMic)
        : null;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppText.body.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
    // Two buttons beside the names leave a phone's title a few letters, so they take their own row there.
    final stacked = compact && withMic != null;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact && lastCallAt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: Text(
                'last call ${callDayLabel(lastCallAt!, now: now)}',
                style: AppText.code.copyWith(color: tokens.textSecondary),
              ),
            ),
          Row(
            children: [
              Expanded(child: text),
              if (buttons != null && !stacked) ...[
                const SizedBox(width: AppSpacing.s12),
                buttons,
              ],
            ],
          ),
          if (buttons != null && stacked) ...[
            const SizedBox(height: AppSpacing.s12),
            Align(alignment: Alignment.centerRight, child: buttons),
          ],
          if (errorMessage != null) ...[
            const SizedBox(height: AppSpacing.s12),
            AppErrorState(message: errorMessage!),
          ],
        ],
      ),
    );
  }

  String _subtitle(
    List<api.VoiceRosterParticipant> here,
    List<String> online, {
    required bool mutedOnly,
  }) {
    return [
      // An empty room is already said by the title; who is online adds nothing there.
      if (here.isNotEmpty && online.isNotEmpty)
        _joinNames(online, 'is online', 'are online'),
      if (!compact && mutedOnly) 'joining starts you muted',
    ].join(' · ');
  }

  String _joinLabel(List<api.VoiceRosterParticipant> here) {
    final verb = rejoin ? 'Rejoin' : 'Join';
    if (compact) return verb;
    return here.isEmpty ? '$verb muted' : '$verb · ${here.length} here';
  }

  /// Join muted alone, or after a plain Join when [withMic] is offered.
  Widget _buttons(
    List<api.VoiceRosterParticipant> here,
    VoidCallback? withMic,
  ) {
    final verb = rejoin ? 'Rejoin' : 'Join';
    final count = [if (here.isNotEmpty) '${here.length} here'];
    final muted = AppButton(
      label: errorMessage != null
          ? 'Try again'
          : withMic == null
          ? _joinLabel(here)
          : '$verb muted',
      semanticLabel: [
        rejoin ? 'Rejoin the call muted' : 'Join the call muted',
        ...count,
      ].join(', '),
      icon: withMic == null ? null : AppIcons.micOff,
      variant: AppButtonVariant.primary,
      onPressed: onJoin,
    );
    if (withMic == null) return muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        AppButton(
          label: verb,
          semanticLabel: [
            rejoin ? 'Rejoin the call' : 'Join the call',
            ...count,
          ].join(', '),
          icon: AppIcons.voice,
          variant: AppButtonVariant.secondary,
          onPressed: withMic,
        ),
        muted,
      ],
    );
  }

  /// Members who can see this channel and are online, not you, not in it.
  List<String> _online(WidgetRef ref, Set<String> inCall) {
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    ref.watch(presenceSeedProvider(channelId));
    final members =
        ref.watch(channelMembersProvider(channelId)).valueOrNull ??
        const <api.UserProfile>[];
    return [
      for (final m in members)
        if (m.id != selfId &&
            !inCall.contains(m.id) &&
            ref.watch(presenceForProvider(m.id)) == AppPresence.online)
          m.displayName,
    ];
  }
}

/// Who is in the call now. Not checked and checked-empty read differently: an empty room is a claim.
String voiceRosterTitle(
  AsyncValue<List<api.VoiceRosterParticipant>> roster, {
  bool compact = false,
}) => switch (roster) {
  AsyncData(value: final people) when people.isNotEmpty => _joinNames(
    [for (final p in people) p.displayName],
    'is here',
    'are here',
  ),
  AsyncData() => compact ? "Nobody's here" : "Nobody's here right now",
  _ => voiceRosterUnknownLine,
};

/// "Kiki is online", "Kiki and Ann are online", "Kiki and 3 others are online".
String _joinNames(List<String> names, String one, String many) =>
    switch (names.length) {
      0 => '',
      1 => '${names.single} $one',
      2 => '${names[0]} and ${names[1]} $many',
      _ => '${names.first} and ${names.length - 1} others $many',
    };
