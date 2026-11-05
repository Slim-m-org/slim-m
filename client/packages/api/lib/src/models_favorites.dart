// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One entry in the caller's favorites. Split out of `models.dart` for the
/// line budget and re-exported there, as every `models_*` file is.
library;

/// What a favorite stands for.
enum FavoriteKind { gif, attachment }

/// A GIF, or an image or video kept from a message, in the caller's own list.
///
/// An [attachment] entry is only a reference; it goes unavailable when its
/// source message is deleted or its channel can no longer be viewed.
class Favorite {
  const Favorite({
    required this.id,
    required this.kind,
    required this.title,
    required this.width,
    required this.height,
    required this.available,
    required this.createdAt,
    this.attachmentId,
    this.contentType,
    this.messageId,
    this.channelId,
  });

  final String id;
  final FavoriteKind kind;
  final String title;

  /// Pixels, or `0` when unknown.
  final int width;
  final int height;
  final bool available;
  final int createdAt;
  final String? attachmentId;
  final String? contentType;

  /// Present only while the entry is available.
  final String? messageId;
  final String? channelId;

  bool get isGif => kind == FavoriteKind.gif;

  factory Favorite.fromJson(Map<String, dynamic> json) => Favorite(
        id: json['id'] as String,
        kind:
            json['kind'] == 'gif' ? FavoriteKind.gif : FavoriteKind.attachment,
        title: json['title'] as String,
        width: json['width'] as int,
        height: json['height'] as int,
        available: json['available'] as bool,
        createdAt: json['created_at'] as int,
        attachmentId: json['attachment_id'] as String?,
        contentType: json['content_type'] as String?,
        messageId: json['message_id'] as String?,
        channelId: json['channel_id'] as String?,
      );
}
