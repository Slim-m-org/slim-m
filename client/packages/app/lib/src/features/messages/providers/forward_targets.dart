// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a message may be forwarded to: every ordinary channel the caller
/// holds SEND_MESSAGES in, plus every DM they have open, each already
/// resolved to a channel id the ordinary send route works on unchanged.
///
/// A forward has its own wire shape now - `forwarded_from_id` on the
/// ordinary send route, which may name a message in any channel the sender
/// can see. Not `reply_to_id`, which the server refuses across channels
/// outright (`SendError::InvalidReplyTarget` in
/// `crates/slimm-server/src/store/messages.rs`: a reply's parent must exist
/// in the exact same channel).
/// This file exists only to answer "where can this go", the one question a
/// forward genuinely needs the server for.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unprefixed extension methods need the declaring library imported - see api.dart's own `show` list comment.
import 'package:slimm_api/api.dart';

import '../../../permissions.dart';
import '../../members/providers/blocks_controller.dart';
import '../../channels/providers/dms.dart' show personalSpaceName;
import '../../channels/providers/group_dm.dart' show channelFromGroupDm;
import '../../../providers/providers.dart';

/// One place a message could be forwarded to.
class ForwardTarget {
  const ForwardTarget({
    required this.channelId,
    required this.label,
    required this.isDm,
    this.isVoice = false,
    this.restricted = false,
    this.isPersonalSpace = false,
    this.userId,
    this.username,
    this.avatarUpdatedAt,
    this.groupMemberIds,
  });

  final String channelId;

  /// The channel's own name, or the DM partner's display name (or
  /// [personalSpaceName] for the caller's own personal space).
  final String label;

  /// Whether this is a DM rather than an ordinary channel - the picker's own
  /// choice of leading glyph, nothing that changes how a send to it works.
  final bool isDm;

  /// Whether this is a voice channel, so the picker draws the rail's glyph.
  final bool isVoice;

  /// Mirrors `Channel.restricted`: the picker draws the rail's lock.
  final bool restricted;

  /// The caller's own Notes, drawn with the rail's notebook rather than their avatar.
  final bool isPersonalSpace;

  /// The DM partner, so the picker can draw their real picture rather than a
  /// generic person glyph. Null for an ordinary channel, which has none.
  final String? userId;

  /// The DM partner's `@username`, which the picker searches as well as
  /// [label]. Null for an ordinary channel, whose name is the only thing it
  /// has. Two people can carry the same display name, and somebody typing
  /// looks for whichever of the two they happen to remember - matching only
  /// the label made a search for the other one answer "No matches", which
  /// reads as a search field that does not work.
  final String? username;

  /// Cache-busts that picture the way every other avatar in the app does;
  /// without it a changed picture keeps showing the old bytes here.
  final int? avatarUpdatedAt;

  /// The other people in a group DM, which the picker draws as a stack of
  /// faces. Null for every target that is not a group.
  final List<String>? groupMemberIds;

  bool get isGroup => groupMemberIds != null;

  /// Whether this target answers to [query], which callers pass already
  /// trimmed and lower-cased. Lives here rather than in the picker so the
  /// rule and the fields it reads stay in one place.
  bool matches(String query) =>
      label.toLowerCase().contains(query) ||
      (username?.toLowerCase().contains(query) ?? false);
}

/// Whether the thing being sent carries attachments: a channel that grants
/// SEND_MESSAGES but not ATTACH_FILES is then left out, since the send would 403.
typedef ForwardTargetsQuery = ({bool hasAttachments});

/// Every target for forwarding or sharing, the message's own channel included:
/// forwarding into it posts a new forwarded copy there, which the server allows.
///
/// Fetched fresh on every watch: a picker's one-shot list, not live state.
final forwardTargetsProvider = FutureProvider.autoDispose
    .family<List<ForwardTarget>, ForwardTargetsQuery>((ref, query) async {
      final client = ref.watch(apiProvider);
      final channels = await client.listChannels();
      final dms = await client.listDirectMessages();
      final blocked = ref.watch(blocksProvider).ids;
      final selfId = ref.watch(sessionProvider).tokens?.userId;

      return [
        for (final channel in channels)
          if ((channel.permissions ?? 0).hasPermission(Perm.sendMessages) &&
              (!query.hasAttachments ||
                  (channel.permissions ?? 0).hasPermission(Perm.attachFiles)))
            ForwardTarget(
              channelId: channel.id,
              label: channel.name,
              isDm: false,
              isVoice: channel.kind == 'voice',
              restricted: channel.restricted ?? false,
            ),
        for (final dm in dms)
          if (dm.isGroup)
            _groupTarget(dm, selfId)
          // `store/dms.rs`: a blocked party is denied SEND_MESSAGES/ATTACH_FILES both ways, and otherwise a DM always grants both to its two participants, so attachments need no extra check here.
          else if (!blocked.contains(dm.user.id))
            ForwardTarget(
              channelId: dm.channelId,
              label: dm.user.id == selfId
                  ? personalSpaceName
                  : dm.user.displayName,
              isDm: true,
              isPersonalSpace: dm.user.id == selfId,
              userId: dm.user.id,
              username: dm.user.username,
              avatarUpdatedAt: dm.user.avatarUpdatedAt,
            ),
      ];
    });

/// A group is named and drawn as the group, and `dm.user` (its first other
/// member) is neither its label nor a reason to hide it when blocked.
ForwardTarget _groupTarget(DmConversation dm, String? selfId) => ForwardTarget(
  channelId: dm.channelId,
  label: channelFromGroupDm(dm, selfId: selfId).name,
  isDm: true,
  groupMemberIds: [
    for (final m in dm.group!.members)
      if (m.id != selfId) m.id,
  ],
);
