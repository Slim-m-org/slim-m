// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The plain value type everything outside this package sees for a locally
/// cached message.
///
/// This is a boundary DTO, not an incidental alias for the drift row: no
/// drift import, no `Insertable`, no `Companion`, nothing from
/// `package:drift/drift.dart` anywhere in this file. `database.dart`'s
/// `MessageRowMapping.toDto` is the only place a drift `MessageRow` becomes
/// one of these, and `MessageStore` is the only caller of it, so a drift
/// type never has to cross into `app` or any other package.
///
/// Every field here mirrors a `messages` column today because `app` reads
/// every one of them somewhere (message actions, the transcript, the reply
/// banner, the composer). That is a fact about what `app` currently needs,
/// not a promise that a future storage-only column drift adds must appear
/// here too - see `docs/decisions/` for the storage-layer boundary this DTO
/// exists to hold.
///
/// Equality and hashing are over every field, matching the drift `DataClass`
/// this replaces: nothing in `app` is known to key a `Set`/`Map` or drive a
/// `riverpod` `select` off a whole `Message` today, but a plain identity
/// default (`==` falling back to `identical`) would be a silent behaviour
/// change for the first caller that ever does, so value equality is kept.
library;

/// What a message was forwarded from, as this cache holds it.
///
/// A snapshot the server took when the forward was sent, so unlike
/// [Message.replyToId] nothing here is resolved locally and nothing here can
/// go stale: it is what was passed on, not what the original says now. The
/// origin may well be in a channel this cache does not hold at all.
///
/// The origin's channel *name* is deliberately absent, on the wire and here.
/// Resolve [channelId] against the channel list this client already holds: a
/// channel it does not hold is one the reader cannot see, so show no origin
/// location and offer no jump.
class ForwardedMessage {
  const ForwardedMessage({
    required this.messageId,
    required this.channelId,
    this.authorId,
    this.authorDisplayName,
    this.authorAvatarUpdatedAt,
    required this.createdAt,
    required this.content,
    this.removed = false,
  });

  final String messageId;
  final String channelId;

  /// Null once the original's author was anonymized, exactly as
  /// [Message.authorId] is.
  final String? authorId;
  final String? authorDisplayName;
  final int? authorAvatarUpdatedAt;

  /// When the original was sent - not when it was forwarded, which is the
  /// carrying message's own [Message.createdAt].
  final int createdAt;

  /// What the original said at the moment it was forwarded.
  final String content;

  /// The original was deleted or aged out; the snapshot fields are blank.
  final bool removed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ForwardedMessage &&
          other.messageId == messageId &&
          other.channelId == channelId &&
          other.authorId == authorId &&
          other.authorDisplayName == authorDisplayName &&
          other.authorAvatarUpdatedAt == authorAvatarUpdatedAt &&
          other.createdAt == createdAt &&
          other.content == content &&
          other.removed == removed);

  @override
  int get hashCode => Object.hash(
        messageId,
        channelId,
        authorId,
        authorDisplayName,
        authorAvatarUpdatedAt,
        createdAt,
        content,
        removed,
      );

  /// Spelled out because a failed equality between two of these is otherwise
  /// reported as two identical "Instance of 'ForwardedMessage'" lines, which
  /// says nothing about which of the eight fields actually differed.
  @override
  String toString() =>
      'ForwardedMessage(messageId: $messageId, channelId: $channelId, '
      'authorId: $authorId, authorDisplayName: $authorDisplayName, '
      'authorAvatarUpdatedAt: $authorAvatarUpdatedAt, '
      'createdAt: $createdAt, content: $content, removed: $removed)';
}

/// One locally cached message, independent of how it is stored.
class Message {
  const Message({
    required this.id,
    required this.channelId,
    this.authorId,
    this.authorDisplayName,
    required this.seq,
    required this.content,
    required this.createdAt,
    this.editedAt,
    this.replyToId,
    this.forwarded,
    this.linkPreviewsRemoved = false,
    required this.pending,
    required this.failed,
    this.failureReason,
  });

  final String id;
  final String channelId;
  final String? authorId;

  /// Sent with the message so rendering a channel needs no lookup per
  /// sender. Null when the author was anonymized, exactly as [authorId] is.
  final String? authorDisplayName;

  /// Server order key. Zero while a message is only local (an optimistic
  /// echo that has not been acknowledged yet), so pending messages sort
  /// last.
  final int seq;
  final String content;
  final int createdAt;
  final int? editedAt;

  /// The message this one replies to, or null. Only ever the id - see
  /// `Messages.replyToId` in `database.dart` for why nothing else about the
  /// parent is copied onto this row.
  final String? replyToId;

  /// What this message forwards, or null when it forwards nothing.
  ///
  /// [content] is the sender's own note alongside it and is often empty; the
  /// thing being forwarded is in here and never mixed into that text.
  final ForwardedMessage? forwarded;

  /// The cards under [content] were removed; they stay hidden.
  final bool linkPreviewsRemoved;

  /// True while the send is in flight. The UI shows these differently and
  /// they are replaced in place by the server's copy on acknowledgement.
  final bool pending;

  /// True when the send failed and the user can retry it.
  final bool failed;

  /// Why [failed] is true, in the server's own words. Null whenever
  /// [failed] is false.
  final String? failureReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == id &&
          other.channelId == channelId &&
          other.authorId == authorId &&
          other.authorDisplayName == authorDisplayName &&
          other.seq == seq &&
          other.content == content &&
          other.createdAt == createdAt &&
          other.editedAt == editedAt &&
          other.replyToId == replyToId &&
          other.forwarded == forwarded &&
          other.linkPreviewsRemoved == linkPreviewsRemoved &&
          other.pending == pending &&
          other.failed == failed &&
          other.failureReason == failureReason);

  @override
  int get hashCode => Object.hash(
        id,
        channelId,
        authorId,
        authorDisplayName,
        seq,
        content,
        createdAt,
        editedAt,
        replyToId,
        forwarded,
        linkPreviewsRemoved,
        pending,
        failed,
        failureReason,
      );
}
