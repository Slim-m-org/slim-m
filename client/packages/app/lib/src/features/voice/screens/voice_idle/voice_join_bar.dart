// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-row join bar at the top of an idle voice channel (design 13):
/// what is true right now - who is here, who is online - and a button that
/// says what it does. Joining always starts muted, so nothing is sent until
/// you unmute.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

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
    this.errorMessage,
    this.canRetry = true,
  });

  final String channelId;
  final bool compact;
  final int? lastCallAt;
  final int now;
  final VoidCallback onJoin;
  final String? errorMessage;
  final bool canRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final roster = ref.watch(voiceRosterProvider(channelId));
    final here = roster.valueOrNull ?? const [];
    final online = _online(ref, {for (final p in here) p.userId});
    // Not checked and checked-empty must read differently: an empty room is a claim.
    final title = switch (roster) {
      AsyncData(value: final people) when people.isNotEmpty => _joinNames(
        [for (final p in people) p.displayName],
        'is here',
        'are here',
      ),
      AsyncData() => compact ? "Nobody's here" : "Nobody's here right now",
      AsyncError() => 'Could not check who is here.',
      _ => "Can't tell who else is here right now.",
    };
    final subtitle = [
      // An empty room is already said by the title; who is online adds nothing there.
      if (here.isNotEmpty && online.isNotEmpty)
        _joinNames(online, 'is online', 'are online'),
      if (!compact) 'joining starts you muted',
    ].join(' · ');
    final label = compact
        ? 'Join'
        : here.isEmpty
        ? 'Join muted'
        : 'Join · ${here.length} here';
    final last = lastCallAt;
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
          if (!compact)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: Text(
                [
                  if (roster.hasValue)
                    here.isEmpty ? 'empty' : '${here.length} in the call',
                  if (last != null) 'last call ${callDayLabel(last, now: now)}',
                ].join(' · '),
                style: AppText.code.copyWith(color: tokens.textSecondary),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Column(
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
                        style: AppText.caption.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s12),
              if (errorMessage == null || canRetry)
                AppButton(
                  label: errorMessage == null ? label : 'Try again',
                  semanticLabel: here.isEmpty
                      ? 'Join the call muted'
                      : 'Join the call muted, ${here.length} here',
                  variant: AppButtonVariant.primary,
                  onPressed: onJoin,
                ),
            ],
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: AppSpacing.s12),
            AppErrorState(message: errorMessage!),
          ],
        ],
      ),
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

/// "Kiki is online", "Kiki and Ann are online", "Kiki and 3 others are online".
String _joinNames(List<String> names, String one, String many) =>
    switch (names.length) {
      0 => '',
      1 => '${names.single} $one',
      2 => '${names[0]} and ${names[1]} $many',
      _ => '${names.first} and ${names.length - 1} others $many',
    };
