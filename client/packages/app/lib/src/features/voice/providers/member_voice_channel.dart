// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which voice channel a member is in, for the chip on their row and card.
///
/// Reads `voiceRosterProvider` for every voice channel in the local store and
/// the live session for a joined call. While a member list is on screen that
/// polls each of those channels (60 s live, 15 s otherwise), whether or not the
/// rail draws it, because a chip cannot know which channel a member is in
/// without asking them all. Only channels in the local store are asked about,
/// which are the ones the server let this viewer see; a hidden participant is
/// never on a roster for anyone else.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../providers/providers.dart';
import 'voice_flags.dart';
import 'voice_roster.dart';

final visibleVoiceChannelsProvider = StreamProvider.autoDispose<List<Channel>>((
  ref,
) {
  final store = ref.watch(storeProvider).valueOrNull;
  if (store == null) return const Stream.empty();
  return store.watchChannels().map(
    (all) => all.where((c) => c.kind == 'voice').toList(growable: false),
  );
});

final _channelByMemberProvider = Provider.autoDispose<Map<String, Channel>>((
  ref,
) {
  final (state, joinedId) = ref.watch(
    voiceFlagsProvider.select((f) => (f.state, f.channelId)),
  );
  final live = state == VoiceSessionState.connected;
  final byMember = <String, Channel>{};
  for (final channel
      in ref.watch(visibleVoiceChannelsProvider).valueOrNull ??
          const <Channel>[]) {
    final Iterable<String> members;
    if (live && channel.id == joinedId) {
      members = ref.watch(voiceParticipantsProvider).map((p) => p.identity);
    } else {
      final roster = ref.watch(voiceRosterProvider(channel.id)).valueOrNull;
      members = (roster ?? const []).map((p) => p.userId);
    }
    for (final id in members) {
      byMember.putIfAbsent(id, () => channel);
    }
  }
  return byMember;
});

/// The voice channel [userId] is in right now, or null.
final memberVoiceChannelProvider = Provider.autoDispose
    .family<Channel?, String>(
      (ref, userId) =>
          ref.watch(_channelByMemberProvider.select((m) => m[userId])),
    );
