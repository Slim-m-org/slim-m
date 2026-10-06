// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `Channel` wire model, split out of `models.dart` for the line budget.
library;

/// A text or voice channel.
class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdAt,
    this.topic,
    this.position = 0,
    this.isPersonalSpace = false,
    this.dmParticipantId,
    this.parentMessageId,
    this.categoryId,
    this.permissions,
    this.slowModeSeconds = 0,
    this.joinMuted = false,
    this.restricted,
  });

  final String id;
  final String name;
  final String kind;
  final int createdAt;

  /// A one-line header shown beside the name. Null for no topic; the server
  /// never stores an empty string, so blank and absent mean the same thing.
  final String? topic;

  /// Sort key among the deployment's live, non-DM channels: lower sorts
  /// first. Deployment-wide, set by [SlimmApiChannelAdmin.reorderChannels],
  /// not a per-device preference. Defaults to 0 for a server too old to send
  /// it, which reads as "unordered" rather than a real position - the same
  /// reason a missing `topic` reads as unknown rather than "no topic".
  /// Meaningless on a DM, which never appears in [SlimmApi.listChannels].
  final int position;

  /// Whether this row is the caller's own personal space: a DM with
  /// themself. Never sent or read on the wire - the server has no such
  /// concept, and [fromJson] always defaults this to false - it is set only
  /// by `channelFromDm` (`providers/dms.dart`), the one place a caller's id
  /// is compared against the DM's other participant. [name] is cosmetic
  /// display copy and must never be used to answer this question: another
  /// member's freely chosen display name can collide with it.
  final bool isPersonalSpace;

  /// The other user in this DM, or null for a non-DM channel. Never sent or
  /// read on the wire, exactly like [isPersonalSpace] and set at the same
  /// place, so a caller that needs to know who a DM is with (blocking) can
  /// read it off the local row instead of fetching the whole `/dms` listing.
  final String? dmParticipantId;

  /// The message this channel is a thread of, or null for an ordinary
  /// channel. A thread's `VIEW_CHANNEL`/`SEND_MESSAGES` inherit the parent
  /// message's own channel, resolved server-side rather than copied; a
  /// thread never appears in [SlimmApi.listChannels] - reach one through
  /// [SlimmApiThreads.openThread] or a message's own `threadChannelId`.
  final String? parentMessageId;

  /// The rail section this channel is filed under, or null for
  /// uncategorised - rendered as an implicit section above every named
  /// category. Decides placement only, never behaviour: see
  /// docs/decisions/0006-channel-categories.md. Absent on a server too old
  /// to send it, which reads the same as uncategorised on this client, since
  /// there is nothing older to distinguish it from.
  final String? categoryId;

  /// The caller's effective bitmask in this channel, already resolved
  /// through thread and DM handling with any timeout subtracted - the
  /// batched sibling of [SlimmApiChannelAdmin.getChannelPermissions]. Present
  /// only on [SlimmApi.listChannels], where every row already carries
  /// VIEW_CHANNEL by construction, so unlike that dedicated route this is
  /// never masked to zero; null everywhere else this model appears, which a
  /// caller must treat as unknown rather than as zero permissions.
  final int? permissions;

  /// The minimum interval, in seconds, a non-`MANAGE_CHANNELS` member must
  /// wait between their own messages here. 0 (the default, and what a
  /// server too old to send this field reads as) means off.
  final int slowModeSeconds;

  /// Whether joining this voice channel starts with the mic off. A default a
  /// member can override, not a lock; false for a server too old to send it.
  final bool joinMuted;

  /// Whether `@everyone` lacks VIEW_CHANNEL here, so the channel is hidden
  /// from ordinary members. Identical for every caller, unlike
  /// [permissions]. Null on a server too old to send it, which reads the
  /// same as false - a client with nothing to say about a channel's
  /// visibility must never claim it is public.
  final bool? restricted;

  bool get isVoice => kind == 'voice';

  /// Whether this row is a thread rather than an ordinary channel - see
  /// [parentMessageId].
  bool get isThread => parentMessageId != null;

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        createdAt: json['created_at'] as int,
        topic: json['topic'] as String?,
        position: json['position'] as int? ?? 0,
        parentMessageId: json['parent_message_id'] as String?,
        categoryId: json['category_id'] as String?,
        permissions: json['permissions'] as int?,
        slowModeSeconds: json['slow_mode_seconds'] as int? ?? 0,
        joinMuted: json['join_muted'] as bool? ?? false,
        restricted: json['restricted'] as bool?,
      );
}

/// A rail section a channel of any kind may be filed under. Carries no
/// permission of its own - see docs/decisions/0006-channel-categories.md.
class ChannelCategory {
  const ChannelCategory({
    required this.id,
    required this.name,
    required this.position,
    required this.createdAt,
  });

  final String id;
  final String name;

  /// Sort key among the deployment's live categories: lower sorts first.
  final int position;
  final int createdAt;

  factory ChannelCategory.fromJson(Map<String, dynamic> json) =>
      ChannelCategory(
        id: json['id'] as String,
        name: json['name'] as String,
        position: json['position'] as int,
        createdAt: json['created_at'] as int,
      );
}

/// What [SlimmApiThreads.getThreadParent] answers: the channel and message a
/// thread hangs off, or all-null together if the given id is not a thread the
/// caller can see - see that method's own doc comment for the masking rule.
class ThreadParent {
  const ThreadParent({
    this.parentChannelId,
    this.parentChannelName,
    this.parentMessageId,
    this.parentContent,
    this.parentDeleted = false,
    this.parentAuthorId,
    this.parentAuthorDisplayName,
  });

  final String? parentChannelId;
  final String? parentChannelName;
  final String? parentMessageId;

  /// The parent message's current text, joined server-side at read time.
  /// Null exactly when [parentDeleted] is true.
  final String? parentContent;

  /// True once the parent message itself has been soft-deleted. A thread
  /// stays open even after its parent is gone, so this is independent of
  /// whether [parentChannelId] and friends resolved at all.
  final bool parentDeleted;

  /// Null once the parent's author account is anonymized.
  final String? parentAuthorId;
  final String? parentAuthorDisplayName;

  bool get isThread => parentChannelId != null;

  factory ThreadParent.fromJson(Map<String, dynamic> json) => ThreadParent(
        parentChannelId: json['parent_channel_id'] as String?,
        parentChannelName: json['parent_channel_name'] as String?,
        parentMessageId: json['parent_message_id'] as String?,
        parentContent: json['parent_content'] as String?,
        parentDeleted: json['parent_deleted'] as bool? ?? false,
        parentAuthorId: json['parent_author_id'] as String?,
        parentAuthorDisplayName: json['parent_author_display_name'] as String?,
      );
}

/// One row of [SlimmApiThreads.listThreads]: a thread's own channel id, the
/// parent message it hangs off (flattened rather than referenced, so a
/// listing needs no per-row follow-up fetch), and how busy and how read it
/// is.
class ThreadListItem {
  const ThreadListItem({
    required this.id,
    required this.parentMessageId,
    required this.parentContent,
    required this.parentAuthorId,
    required this.parentAuthorDisplayName,
    required this.createdAt,
    required this.replyCount,
    required this.lastReplyAt,
    required this.unreadCount,
  });

  /// The thread's own channel id. Open (or reuse) it with
  /// [SlimmApiThreads.openThread].
  final String id;
  final String parentMessageId;

  /// The parent message's current text, joined server-side at read time -
  /// not a snapshot frozen at whenever the thread opened.
  final String parentContent;

  /// Null once the parent's author account is anonymized.
  final String? parentAuthorId;
  final String? parentAuthorDisplayName;
  final int createdAt;

  /// Undeleted replies in this thread. Can be 0.
  final int replyCount;

  /// When the newest undeleted reply was sent, or null when [replyCount] is 0.
  final int? lastReplyAt;

  /// How many of this thread's live messages the caller has not yet read -
  /// the same read-tracking every channel already carries, surfaced here.
  final int unreadCount;

  bool get isUnread => unreadCount > 0;

  factory ThreadListItem.fromJson(Map<String, dynamic> json) => ThreadListItem(
        id: json['id'] as String,
        parentMessageId: json['parent_message_id'] as String,
        parentContent: json['parent_content'] as String,
        parentAuthorId: json['parent_author_id'] as String?,
        parentAuthorDisplayName: json['parent_author_display_name'] as String?,
        createdAt: json['created_at'] as int,
        replyCount: json['reply_count'] as int,
        lastReplyAt: json['last_reply_at'] as int?,
        unreadCount: json['unread_count'] as int,
      );
}

/// One rail section's ordered contents, as a drag produces: the category it
/// names (null for the implicit uncategorised section) and every channel now
/// filed under it, in display order. The request shape
/// [SlimmApiChannelAdmin.reorderChannels] sends.
class ChannelOrderGroup {
  const ChannelOrderGroup({required this.categoryId, required this.channelIds});

  final String? categoryId;
  final List<String> channelIds;

  Map<String, dynamic> toJson() => {
        'category_id': categoryId,
        'channel_ids': channelIds,
      };
}
