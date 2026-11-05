// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The caller's own favorite GIFs and message media. The `gifs` tag.
extension SlimmApiFavorites on SlimmApi {
  /// The whole list, in the order the caller arranged it.
  Future<List<Favorite>> listFavorites() async {
    final json = await send('GET', '/favorites');
    return (json as List<dynamic>)
        .map((f) => Favorite.fromJson(f as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Favorites a live GIF result. Idempotent on [id] and on the GIF itself.
  Future<Favorite> addGifFavorite(String id, {required String gifId}) async {
    final json = await send(
      'POST',
      '/favorites',
      body: {'id': id, 'kind': 'gif', 'gif_id': gifId},
    );
    return Favorite.fromJson(json as Map<String, dynamic>);
  }

  /// Favorites an image or video attached to a message the caller can view.
  Future<Favorite> addAttachmentFavorite(
    String id, {
    required String messageId,
    required String attachmentId,
  }) async {
    final json = await send(
      'POST',
      '/favorites',
      body: {
        'id': id,
        'kind': 'attachment',
        'message_id': messageId,
        'attachment_id': attachmentId,
      },
    );
    return Favorite.fromJson(json as Map<String, dynamic>);
  }

  /// Removes an entry. Idempotent, and never refused.
  Future<void> removeFavorite(String id) =>
      send('DELETE', '/favorites/$id', expectNoContent: true);

  /// Puts [ids] first, in order; entries not named keep their place after.
  Future<void> reorderFavorites(List<String> ids) => send(
        'PUT',
        '/favorites/order',
        body: {'ids': ids},
        expectNoContent: true,
      );

  /// A GIF favorite's thumbnail, streamed through this server.
  Future<FetchedBytes> fetchFavoritePreview(String id) =>
      fetchBytes('/favorites/$id/preview');

  /// Turns a favorite into an attachment a message can carry.
  ///
  /// An attachment favorite whose source is gone answers 409
  /// ([ConflictException]) rather than serving the file.
  Future<Attachment> selectFavorite(String id, {String? channelId}) async {
    final json = await send(
      'POST',
      '/favorites/$id/select',
      body: {if (channelId != null) 'channel_id': channelId},
    );
    return Attachment.fromJson(json as Map<String, dynamic>);
  }
}
