// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a message was forwarded from. Split out of `models.dart` for the
/// line budget and re-exported there, as every `models_*` file is.
library;

import 'text_marks.dart';

/// What a message was forwarded from.
///
/// A snapshot the server took when the forward was sent, not a live read, so
/// it stays answerable after the original is edited or deleted - the opposite
/// of [Message.replyToId], which resolves its parent every time and for good
/// reason: a reply shares a channel with its parent, a forward does not.
///
/// The origin's channel name is deliberately not on the wire. Resolve
/// [channelId] against the channel list this client already holds: a channel
/// it does not hold is one the reader has no access to, so show no origin
/// location and offer no jump rather than asking for one that would be
/// refused.
class ForwardedMessage {
  const ForwardedMessage({
    required this.messageId,
    required this.channelId,
    required this.authorId,
    required this.authorDisplayName,
    required this.authorAvatarUpdatedAt,
    required this.createdAt,
    required this.content,
    this.removed = false,
  });

  final String messageId;
  final String channelId;

  /// Null once the original's author has been anonymized, exactly as
  /// [Message.authorId] is.
  final String? authorId;
  final String? authorDisplayName;

  /// Builds the author's avatar URL without a second lookup, and busts its
  /// cache when they change it.
  final int? authorAvatarUpdatedAt;

  /// When the original was sent - not when it was forwarded, which is the
  /// carrying message's own [Message.createdAt].
  final int createdAt;

  /// What the original said at the moment it was forwarded.
  final String content;

  /// The original was deleted or aged out, so the snapshot fields are blank
  /// and the card says so instead.
  final bool removed;

  factory ForwardedMessage.fromJson(Map<String, dynamic> json) =>
      ForwardedMessage(
        messageId: json['message_id'] as String,
        channelId: json['channel_id'] as String,
        authorId: json['author_id'] as String?,
        authorDisplayName:
            capOptionalMarks(json['author_display_name'] as String?),
        authorAvatarUpdatedAt: json['author_avatar_updated_at'] as int?,
        createdAt: json['created_at'] as int,
        content: json['content'] as String,
        removed: json['removed'] as bool? ?? false,
      );
}
