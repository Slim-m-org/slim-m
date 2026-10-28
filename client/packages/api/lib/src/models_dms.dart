// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Direct-message conversations: the `dms` tag.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

import 'models_users.dart';

/// One of the caller's DM conversations: a channel like any other for
/// messages, search, and sync, plus the other participant and the caller's
/// own unread count in it.
class DmConversation {
  const DmConversation({
    required this.channelId,
    required this.user,
    required this.unread,
    required this.createdAt,
    this.group,
  });

  final String channelId;

  /// The other participant of a pair. For a group DM, its first other
  /// participant; read [group] for the whole roster.
  final UserProfile user;
  final int unread;

  /// Unix milliseconds the DM channel was first opened.
  final int createdAt;

  /// Set only for a group DM (decision 0095).
  final GroupDmInfo? group;

  bool get isGroup => group != null;

  factory DmConversation.fromJson(Map<String, dynamic> json) => DmConversation(
        channelId: json['channel_id'] as String,
        user: UserProfile.fromJson(json['user'] as Map<String, dynamic>),
        unread: json['unread'] as int,
        createdAt: json['created_at'] as int,
        group: json['group'] == null
            ? null
            : GroupDmInfo.fromJson(json['group'] as Map<String, dynamic>),
      );
}

/// What a group DM adds to its [DmConversation].
class GroupDmInfo {
  const GroupDmInfo({required this.name, required this.members});

  /// The custom name, or null when each client shows the default built from
  /// the members.
  final String? name;

  /// Every participant, the caller included, oldest member first.
  final List<UserProfile> members;

  factory GroupDmInfo.fromJson(Map<String, dynamic> json) => GroupDmInfo(
        name: json['name'] as String?,
        members: (json['members'] as List<dynamic>)
            .map((m) => UserProfile.fromJson(m as Map<String, dynamic>))
            .toList(growable: false),
      );
}
