// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the other people in a DM are still in the Space.
///
/// Nothing new comes from the server: the roster (`GET /members`) leaves out
/// anyone removed or deleted, and a profile lookup says which of the two it was.
/// The server still accepts a message to them, so the client says it will not be read.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';
import '../../members/providers/member_presence.dart';
import '../../members/providers/user_profiles.dart';

enum DmDeparture {
  /// Removed from or gone from the roster; the account may still exist.
  left,

  /// The account itself was deleted.
  deleted;

  String get label => switch (this) {
    DmDeparture.left => 'Left the Space',
    DmDeparture.deleted => 'Deleted user',
  };

  /// What a person sees in place of "nobody is typing yet" before they write.
  String get notice => switch (this) {
    DmDeparture.left =>
      'Left the Space. They will not see new messages unless they come back.',
    DmDeparture.deleted =>
      'This account was deleted. Nobody will see new messages here.',
  };
}

/// The conversation's people, as [dmDepartureProvider] keys it.
typedef DmPeers = ({String? peerId, String? memberIds});

DmPeers dmPeersOf(Channel channel) =>
    (peerId: channel.dmParticipantId, memberIds: channel.dmMemberIds);

/// Null while the roster is unknown, so a slow load never reads as everyone leaving.
final spaceMemberIdsProvider = Provider.autoDispose<Set<String>?>((ref) {
  final roster = ref.watch(membersProvider).valueOrNull;
  return roster == null ? null : {for (final m in roster) m.id};
});

/// Null while anyone else in the conversation is still here.
///
/// A group counts as left only once everyone but the caller has gone.
final dmDepartureProvider = Provider.autoDispose.family<DmDeparture?, DmPeers>((
  ref,
  peers,
) {
  final roster = ref.watch(spaceMemberIdsProvider);
  if (roster == null) return null;
  final selfId = ref.watch(sessionProvider).tokens?.userId;
  final peerId = peers.peerId;
  final others = [
    if (peerId != null)
      peerId
    else
      for (final id in (peers.memberIds ?? '').split(','))
        if (id.isNotEmpty && id != selfId) id,
  ];
  if (others.isEmpty || others.any(roster.contains)) return null;
  if (others.length == 1) {
    final profile = ref.watch(userProfileProvider(others.single));
    if (profile.hasValue && profile.value == null) {
      return DmDeparture.deleted;
    }
  }
  return DmDeparture.left;
});
