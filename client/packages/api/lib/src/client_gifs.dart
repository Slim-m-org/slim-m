// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// GIF search, proxied end to end through this deployment's own server
/// rather than reaching a third-party provider directly - see
/// `Version.gifSearchEnabled` for the capability check a caller should make
/// before ever calling any of these. The `gifs` tag.
extension SlimmApiGifs on SlimmApi {
  /// Searches the deployment's configured GIF provider. Each result's [id]
  /// is an opaque token, redeemable at [fetchGifPreview] and [selectGif] for
  /// a short time - never the provider's own id or a raw CDN URL.
  Future<List<GifResult>> searchGifs(
    String query, {
    int? limit,
    String? channelId,
  }) async {
    final json = await _send(
      'GET',
      '/gifs/search',
      query: {
        'q': query,
        if (limit != null) 'limit': '$limit',
        if (channelId != null) 'channel_id': channelId,
      },
    );
    final results = (json as Map<String, dynamic>)['results'] as List<dynamic>;
    return results
        .map((r) => GifResult.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// The deployment's configured provider's current trending results - the
  /// picker's own default content before a member types a query. Same
  /// proxying and tokenizing as [searchGifs]; each result's [id] is redeemable
  /// at [fetchGifPreview] and [selectGif] exactly the same way.
  Future<List<GifResult>> fetchTrendingGifs({
    int? limit,
    String? channelId,
  }) async {
    final json = await _send(
      'GET',
      '/gifs/trending',
      query: {
        if (limit != null) 'limit': '$limit',
        if (channelId != null) 'channel_id': channelId,
      },
    );
    final results = (json as Map<String, dynamic>)['results'] as List<dynamic>;
    return results
        .map((r) => GifResult.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Fetches a search result's thumbnail, streamed through this server
  /// rather than a client asking the provider's own CDN directly.
  ///
  /// [channelId] names where the GIF is headed, so ATTACH_FILES is checked
  /// there and a channel overwrite granting it counts.
  Future<FetchedBytes> fetchGifPreview(String gifId, {String? channelId}) =>
      _fetchBytes(
        '/gifs/preview/$gifId',
        query: {if (channelId != null) 'channel_id': channelId},
      );

  /// Downloads the full-resolution image through this server and stores it
  /// as an ordinary attachment; the returned [Attachment.id] may be
  /// referenced in `attachment_ids` on [SlimmApiMessages.sendMessage] exactly
  /// like one from [SlimmApiAttachments.uploadAttachment].
  Future<Attachment> selectGif(String gifId, {String? channelId}) async {
    final json = await _send(
      'POST',
      '/gifs/select',
      body: {'id': gifId, if (channelId != null) 'channel_id': channelId},
    );
    return Attachment.fromJson(json as Map<String, dynamic>);
  }
}
