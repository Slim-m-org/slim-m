// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message op stream: how an edit or a delete reaches a client that was
/// offline when it happened.
///
/// `messages.seq` is allocated once, at creation, so a cursor over it can only
/// ever report messages that did not exist last time. An edit changes content
/// in place and a delete sets a tombstone, and neither is visible to a
/// `seq > cursor` read at any later point. This is a second, independent
/// sequence over the same channel, dense over the ops it carries, riding the
/// request `/sync` already makes.
///
/// A sibling of `models.dart`, which holds `ScopeCursor` and `ScopeDelta`.
library;

/// One row of the message op stream.
///
/// No op carries an actor, on any kind, ever. The live `message.deleted` frame
/// carries only the ids a connection needs to drop it from view, and a
/// catch-up feed that named the moderator would hand every member, over a
/// different route, exactly what the live path withholds.
sealed class MessageOp {
  const MessageOp({
    required this.seq,
    required this.messageId,
    required this.createdAt,
  });

  final int seq;
  final String messageId;
  final int createdAt;

  factory MessageOp.fromJson(Map<String, dynamic> json) {
    final seq = json['seq'] as int;
    final messageId = json['message_id'] as String;
    final createdAt = json['created_at'] as int? ?? 0;
    return switch (json['kind']) {
      'edit' => MessageEditOp(
          seq: seq,
          messageId: messageId,
          createdAt: createdAt,
          content: json['content'] as String?,
          editedAt: json['edited_at'] as int?,
          forwardedRemoved: json['forwarded_removed'] as bool? ?? false,
          linkPreviewsRemoved: json['link_previews_removed'] as bool? ?? false,
        ),
      'delete' => MessageDeleteOp(
          seq: seq,
          messageId: messageId,
          createdAt: createdAt,
        ),
      _ => MessageUnknownOp(
          seq: seq,
          messageId: messageId,
          createdAt: createdAt,
        ),
    };
  }
}

/// A message's content changed.
///
/// [content] is null when the message has since been deleted, since content is
/// joined at read time rather than stored on the op: a later delete op in the
/// same stream is what the client acts on instead. It is also null on an
/// earlier edit collapsed within a page, where only the last op naming a
/// message carries text. Either way the op keeps its seq, so the cursor still
/// advances through it.
class MessageEditOp extends MessageOp {
  const MessageEditOp({
    required super.seq,
    required super.messageId,
    required super.createdAt,
    required this.content,
    required this.editedAt,
    this.forwardedRemoved = false,
    this.linkPreviewsRemoved = false,
  });

  final String? content;
  final int? editedAt;

  /// The message forwards something whose original was removed; clear the
  /// snapshot even when [content] is absent.
  final bool forwardedRemoved;

  /// The message's link-preview cards were removed; hide them even when
  /// [content] is absent.
  final bool linkPreviewsRemoved;
}

/// A message was deleted.
class MessageDeleteOp extends MessageOp {
  const MessageDeleteOp({
    required super.seq,
    required super.messageId,
    required super.createdAt,
  });
}

/// A kind this client does not recognise, from a newer server.
///
/// This case must exist as a value rather than being dropped by a `switch`
/// default. A dropped op advances no cursor and reconciles nothing, so the
/// client would silently keep a stale copy of whatever it named, which is the
/// one failure this whole surface exists to prevent. A caller that cannot
/// interpret one should reset the channel rather than skip it.
class MessageUnknownOp extends MessageOp {
  const MessageUnknownOp({
    required super.seq,
    required super.messageId,
    required super.createdAt,
  });
}
